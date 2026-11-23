import 'dart:math' as math;

import 'book_content.dart';
import 'pdf_layout.dart';

/// Rebuilds reflowable text from positioned PDF lines: drops running
/// headers, footers and page numbers, finds headings and chapters, and joins
/// lines into paragraphs.
class PdfTextAnalyzer {
  const PdfTextAnalyzer();

  /// Pages with fewer visible characters than this are treated as images.
  static const imagePageThreshold = 3;

  static final chapterPattern = RegExp(
    r'^(chapter|book|part|volume|act|canto)\s+'
    r'([0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|'
    r'eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|'
    r'nineteen|twenty|the\s+\w+)\b'
    r'|^(prologue|epilogue|preface|foreword|introduction|afterword|appendix|'
    r'contents|table of contents|acknowledgements|acknowledgments|'
    r'bibliography|glossary|index|notes)\b',
    caseSensitive: false,
  );
  static final _bareChapterLabel = RegExp(
    r'^(chapter|book|part|volume|act|canto)\s+\S+\.?$',
    caseSensitive: false,
  );
  static final _pageNumber = RegExp(
    r'^(page\s*)?([0-9]{1,4}|[ivxlcdm]{1,7})(\s*(of|/)\s*[0-9]{1,4})?$'
    r'|^[-–—]\s*[0-9]{1,4}\s*[-–—]$'
    r'|^\[\s*[0-9]{1,4}\s*\]$',
    caseSensitive: false,
  );
  static final _ocrPageNumber = RegExp(r'^[0-9lIOoSZ]{1,3}$');
  static final _terminal =RegExp('[.!?:;"”’)\\]»…]\$');
  static final _letter = RegExp(r'\p{L}', unicode: true);
  static final _lowerStart = RegExp(r'^\p{Ll}', unicode: true);

  BookAnalysis analyze(
    List<PdfPageLayout> pages, {
    List<PdfOutlineEntry> outline = const [],
  }) {
    final body = bodySize(pages);
    final cleaned = removePageFurniture(pages, bodySize: body);
    final lines = _annotate(cleaned, body, outline);
    final leading = _leading(lines, body);
    final imagePages = [
      for (final page in cleaned)
        if (page.characterCount < imagePageThreshold) page.pageNumber,
    ];
    final chapters = _buildChapters(
      lines,
      cleaned,
      body: body,
      leading: leading,
      outline: outline,
      imagePages: imagePages.toSet(),
    );
    return BookAnalysis(chapters: chapters, bodySize: body);
  }

  // ---------------------------------------------------------------------------
  // Running headers, footers and page numbers

  /// Removes lines that repeat at the top or bottom of many pages, and bare
  /// page numbers in the page margins.
  ///
  /// Running headers are set no larger than body text, so bigger lines
  /// (chapter titles at the top of a page) are kept.
  List<PdfPageLayout> removePageFurniture(
    List<PdfPageLayout> pages, {
    double? bodySize,
  }) {
    final body = bodySize ?? this.bodySize(pages);
    final counts = <String, int>{};
    for (final page in pages) {
      final seen = <String>{};
      for (final line in _marginLines(page)) {
        final key = _furnitureKey(page, line);
        if (seen.add(key)) counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final textPages = pages.where((page) => page.lines.isNotEmpty).length;
    final threshold = textPages <= 6 ? 2 : 3;

    return [
      for (final page in pages)
        PdfPageLayout(
          pageNumber: page.pageNumber,
          width: page.width,
          height: page.height,
          lines: () {
            final margin = _marginLines(page).toSet();
            return page.lines.where((line) {
              if (!margin.contains(line)) return true;
              if (_pageNumber.hasMatch(line.text.trim())) return false;
              if (line.size > body * 1.15) return true;
              // OCR often reads page numbers as letters ("lO" for 10).
              if (_ocrPageNumber.hasMatch(line.text.trim())) return false;
              final count = counts[_furnitureKey(page, line)] ?? 0;
              return count < threshold;
            }).toList();
          }(),
        ),
    ];
  }

  /// Up to two lines in the top and bottom 12% of the page.
  Iterable<PdfTextLine> _marginLines(PdfPageLayout page) sync* {
    if (page.height <= 0) return;
    final top = page.lines
        .where((line) => line.bottom > page.height * 0.88)
        .toList()
      ..sort((a, b) => b.top.compareTo(a.top));
    final bottom = page.lines
        .where((line) => line.top < page.height * 0.12)
        .toList()
      ..sort((a, b) => a.bottom.compareTo(b.bottom));
    yield* top.take(2);
    yield* bottom.take(2);
  }

  String _furnitureKey(PdfPageLayout page, PdfTextLine line) {
    final zone = line.bottom > page.height / 2 ? 'top' : 'bottom';
    var text = line.text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    // Page numbers inside a running header ("12 THE TIME MACHINE") vary
    // from page to page; mask them, but only when there are a few, so
    // ordinary text full of numbers never looks repeated.
    if (RegExp(r'[0-9]+').allMatches(text).length <= 2) {
      text = text
          .replaceAll(RegExp(r'[0-9]+'), '#')
          .replaceAll(RegExp(r'\b[ivxlcdm]+\b'), '#')
          // OCR splits "11" into "1 1".
          .replaceAll(RegExp(r'#(\s*#)+'), '#');
    }
    return '$zone:$text';
  }

  // ---------------------------------------------------------------------------
  // Sizes and headings

  /// The most common font size, weighted by text length.
  double bodySize(List<PdfPageLayout> pages) {
    final histogram = <int, int>{};
    for (final page in pages) {
      for (final line in page.lines) {
        final bucket = (line.size * 2).round();
        histogram[bucket] = (histogram[bucket] ?? 0) + line.text.length;
      }
    }
    if (histogram.isEmpty) return 11;
    final best = histogram.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.key / 2;
  }

  List<_Line> _annotate(
    List<PdfPageLayout> pages,
    double body,
    List<PdfOutlineEntry> outline,
  ) {
    final outlineByPage = <int, List<PdfOutlineEntry>>{};
    for (final entry in outline) {
      final page = entry.pageNumber;
      if (page != null) (outlineByPage[page] ??= []).add(entry);
    }
    final result = <_Line>[];
    for (final page in pages) {
      final lines = page.lines;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        var colLeft = line.left;
        var colRight = line.right;
        for (final other in lines) {
          if (_overlapsHorizontally(line, other)) {
            colLeft = math.min(colLeft, other.left);
            colRight = math.max(colRight, other.right);
          }
        }
        final text = line.text;
        final bigger =
            line.size >= body * 1.18 &&
            text.length <= 160 &&
            looksLikeHeading(text);
        final columnWidth = math.max(colRight - colLeft, 1.0);
        final short =
            line.width < columnWidth * 0.8 || lines.length < 4 || text.length < 40;
        final pattern =
            chapterPattern.hasMatch(text.trim()) && text.length <= 80 && short;
        PdfOutlineEntry? outlineEntry;
        for (final entry in outlineByPage[page.pageNumber] ?? const []) {
          if (_matchesTitle(text, entry.title)) {
            outlineEntry = entry;
            break;
          }
        }
        result.add(
          _Line(
            line: line,
            page: page.pageNumber,
            colLeft: colLeft,
            colRight: colRight,
            bigger: bigger,
            pattern: pattern,
            outline: outlineEntry,
          ),
        );
      }
    }
    return result;
  }

  static final _headingEndingNot = RegExp('[,;]\$|[.!?,][\'"”’]\$');

  /// Filters out large text that is not a heading: OCR noise, stamps and
  /// numbers, or a fragment of a sentence.
  static bool looksLikeHeading(String text) {
    final value = text.trim();
    final visible = value.replaceAll(RegExp(r'\s'), '');
    if (visible.length < 2) return false;
    final letters = _letter.allMatches(visible).length;
    if (letters < 2 || letters / visible.length < 0.6) return false;
    if (_lowerStart.hasMatch(value)) return false;
    if (_headingEndingNot.hasMatch(value)) return false;
    return true;
  }

  bool _overlapsHorizontally(PdfTextLine a, PdfTextLine b) {
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    return overlap > math.min(a.width, b.width) * 0.5;
  }

  static String normalizeTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  bool _matchesTitle(String line, String title) {
    final a = normalizeTitle(line);
    final b = normalizeTitle(title);
    if (a.length < 2 || b.length < 2) return false;
    return a == b || (a.startsWith(b) && b.length >= 4) || (b.startsWith(a) && a.length >= 4);
  }

  double _leading(List<_Line> lines, double body) {
    final gaps = <double>[];
    for (var i = 1; i < lines.length; i++) {
      final previous = lines[i - 1];
      final current = lines[i];
      if (previous.page != current.page) continue;
      if (previous.isHeading || current.isHeading) continue;
      final gap = previous.line.bottom - current.line.bottom;
      if (gap > 0 && gap < body * 3) gaps.add(gap);
    }
    if (gaps.isEmpty) return body * 1.3;
    gaps.sort();
    return gaps[gaps.length ~/ 2];
  }

  // ---------------------------------------------------------------------------
  // Chapters and paragraphs

  List<BookChapter> _buildChapters(
    List<_Line> lines,
    List<PdfPageLayout> pages, {
    required double body,
    required double leading,
    required List<PdfOutlineEntry> outline,
    required Set<int> imagePages,
  }) {
    final headings = _mergeHeadings(lines);
    final levels = _headingLevels(headings, body);
    final split = _splitRule(headings, levels, outline);

    // Outline entries whose title is not printed on their page still start
    // a chapter at the top of that page.
    final matchedOutline = <PdfOutlineEntry>{
      for (final line in lines)
        if (line.outline != null) line.outline!,
    };
    final pendingOutline = <int, List<PdfOutlineEntry>>{};
    if (split.useOutline) {
      for (final entry in outline) {
        if (entry.level == 0 &&
            entry.pageNumber != null &&
            !matchedOutline.contains(entry)) {
          (pendingOutline[entry.pageNumber!] ??= []).add(entry);
        }
      }
    }

    final chapters = <BookChapter>[];
    var title = '';
    var blocks = <BookBlock>[];
    var anyHeadingSplit = false;
    final paragraph = _ParagraphBuilder();
    final heldImages = <int>[];
    _Line? previous;

    void flushParagraph() {
      final block = paragraph.build();
      if (block != null) blocks.add(block);
      for (final page in heldImages) {
        blocks.add(PageImageBlock(page));
      }
      heldImages.clear();
    }

    void startChapter(String newTitle) {
      flushParagraph();
      if (blocks.isNotEmpty) {
        chapters.add(BookChapter(title: title, blocks: blocks));
      }
      title = newTitle;
      blocks = <BookBlock>[];
      previous = null;
    }

    final pageNumbers = pages.map((page) => page.pageNumber).toList();
    var pageCursor = 0;
    void visitPagesUpTo(int pageNumber) {
      while (pageCursor < pageNumbers.length &&
          pageNumbers[pageCursor] <= pageNumber) {
        final number = pageNumbers[pageCursor];
        for (final entry in pendingOutline[number] ?? const []) {
          startChapter(entry.title);
          blocks.add(HeadingBlock(entry.title));
          anyHeadingSplit = true;
        }
        if (imagePages.contains(number)) {
          if (paragraph.isEmpty) {
            blocks.add(PageImageBlock(number));
          } else {
            heldImages.add(number);
          }
        }
        pageCursor++;
      }
    }

    for (var i = 0; i < headings.length; i++) {
      final item = headings[i];
      visitPagesUpTo(item.first.page);
      if (item.isHeading) {
        final text = item.text;
        final level = levels[i] ?? 1;
        if (split.splits(item, level)) {
          startChapter(text);
          anyHeadingSplit = true;
          blocks.add(HeadingBlock(text, level: 1));
        } else {
          flushParagraph();
          if (title.isEmpty && blocks.isEmpty) title = text;
          final relative = split.relativeLevel(level);
          blocks.add(HeadingBlock(text, level: relative));
          previous = null;
        }
        continue;
      }
      final line = item.first;
      if (previous != null &&
          !_continuesParagraph(previous!, line, body: body, leading: leading)) {
        flushParagraph();
      }
      paragraph.add(line);
      previous = line;
    }
    visitPagesUpTo(1 << 30);
    flushParagraph();
    if (blocks.isNotEmpty) {
      chapters.add(BookChapter(title: title, blocks: blocks));
    }

    if (!anyHeadingSplit) {
      return _chunkByPages(chapters, lines, pages);
    }
    return [
      for (var i = 0; i < chapters.length; i++)
        BookChapter(
          title: chapters[i].title.isEmpty
              ? (i == 0 ? 'Beginning' : 'Section ${i + 1}')
              : chapters[i].title,
          blocks: chapters[i].blocks,
        ),
    ];
  }

  /// Groups consecutive heading lines (a multi-line title, or "CHAPTER IV"
  /// above its name) into one item. Body lines become single-line items.
  List<_Item> _mergeHeadings(List<_Line> lines) {
    final items = <_Item>[];
    for (final line in lines) {
      final last = items.isEmpty ? null : items.last;
      if (line.isHeading &&
          last != null &&
          last.isHeading &&
          last.first.page == line.page) {
        final previous = last.lines.last;
        final gap = previous.line.bottom - line.line.top;
        final size = math.max(previous.line.size, line.line.size);
        final similar =
            (previous.line.size - line.line.size).abs() <= size * 0.12;
        // "CHAPTER IV" above the chapter's name, set at least as large.
        final labelThenName =
            _bareChapterLabel.hasMatch(last.text.trim()) &&
            !line.pattern &&
            line.line.size >= previous.line.size * 0.9;
        if (gap < size * 2.5 && (similar || labelThenName)) {
          last.lines.add(line);
          continue;
        }
      }
      items.add(_Item([line]));
    }
    return items;
  }

  /// Heading level by size rank: the largest heading size is level 1.
  Map<int, int> _headingLevels(List<_Item> items, double body) {
    final sizes = <int>{};
    for (final item in items) {
      if (item.isHeading && item.bigger) sizes.add(item.size.round());
    }
    final ranked = sizes.toList()..sort((a, b) => b.compareTo(a));
    final levels = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (!item.isHeading) continue;
      final outline = item.outlineEntry;
      if (outline != null) {
        levels[i] = outline.level + 1;
      } else if (item.bigger) {
        levels[i] = ranked.indexOf(item.size.round()) + 1;
      } else {
        // A "Chapter …" line in body size: as prominent as the smallest
        // heading size.
        levels[i] = ranked.length + 1;
      }
    }
    return levels;
  }

  _SplitRule _splitRule(
    List<_Item> items,
    Map<int, int> levels,
    List<PdfOutlineEntry> outline,
  ) {
    final topLevelOutline = outline
        .where((entry) => entry.level == 0 && entry.pageNumber != null)
        .length;
    if (topLevelOutline >= 2) {
      return const _SplitRule(useOutline: true, level: 1);
    }
    final patternLevels = <int>[];
    final counts = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      final level = levels[i];
      if (level == null) continue;
      counts[level] = (counts[level] ?? 0) + 1;
      if (items[i].pattern) patternLevels.add(level);
    }
    if (patternLevels.length >= 2) {
      patternLevels.sort();
      return _SplitRule(level: patternLevels[patternLevels.length ~/ 2]);
    }
    final repeated = counts.entries.where((entry) => entry.value >= 2).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (repeated.isNotEmpty) return _SplitRule(level: repeated.first.key);
    return const _SplitRule(level: 0);
  }

  bool _continuesParagraph(
    _Line previous,
    _Line current, {
    required double body,
    required double leading,
  }) {
    final p = previous.line;
    final c = current.line;
    final size = math.max(c.size, body);
    final previousIndent = p.left - previous.colLeft;
    final currentIndent = c.left - current.colLeft;
    final previousShort = p.right < previous.colRight - size * 2.5;
    final endsSentence = _terminal.hasMatch(p.text);
    if (previousShort && endsSentence) return false;
    // A word split by a hyphen, or a sentence running on in lower case,
    // never starts a new paragraph, whatever the spacing (OCR line boxes
    // are irregular).
    if (!endsSentence && _lowerStart.hasMatch(c.text)) return true;

    final sameFlow =
        previous.page == current.page &&
        c.top < p.top &&
        _overlapsHorizontally(p, c);
    if (sameFlow) {
      final gap = p.bottom - c.bottom;
      if (gap > leading * 1.45) return false;
      if (currentIndent > size * 0.7 && previousIndent < size * 0.5) {
        return false;
      }
      // A short line without closing punctuation followed by a flush line
      // is verse or a list: it stays in the paragraph, and the paragraph
      // keeps its line breaks.
      return true;
    }
    // Page or column change.
    if (currentIndent > size * 0.7) return false;
    return true;
  }

  List<BookChapter> _chunkByPages(
    List<BookChapter> chapters,
    List<_Line> lines,
    List<PdfPageLayout> pages,
  ) {
    final blocks = [for (final chapter in chapters) ...chapter.blocks];
    if (blocks.isEmpty) return const [];
    if (pages.length <= 15) {
      return [
        BookChapter(
          title: chapters.isNotEmpty && chapters.first.title.isNotEmpty
              ? chapters.first.title
              : 'Text',
          blocks: blocks,
        ),
      ];
    }
    // No structure: split roughly every 12 pages of text so the reader
    // never has to lay out one enormous file.
    final chunks = <BookChapter>[];
    const target = 12 * 2200;
    var current = <BookBlock>[];
    var length = 0;
    for (final block in blocks) {
      current.add(block);
      length += switch (block) {
        ParagraphBlock(:final text) => text.length,
        HeadingBlock(:final text) => text.length,
        PageImageBlock() => 2200,
      };
      if (length >= target) {
        chunks.add(BookChapter(title: 'Part ${chunks.length + 1}', blocks: current));
        current = [];
        length = 0;
      }
    }
    if (current.isNotEmpty) {
      chunks.add(BookChapter(title: 'Part ${chunks.length + 1}', blocks: current));
    }
    return chunks;
  }
}

class BookAnalysis {
  const BookAnalysis({required this.chapters, required this.bodySize});

  final List<BookChapter> chapters;
  final double bodySize;
}

class _Line {
  _Line({
    required this.line,
    required this.page,
    required this.colLeft,
    required this.colRight,
    required this.bigger,
    required this.pattern,
    required this.outline,
  });

  final PdfTextLine line;
  final int page;
  final double colLeft;
  final double colRight;
  final bool bigger;
  final bool pattern;
  final PdfOutlineEntry? outline;

  bool get isHeading => bigger || pattern || outline != null;
}

class _Item {
  _Item(this.lines);

  final List<_Line> lines;

  _Line get first => lines.first;
  bool get isHeading => first.isHeading;
  bool get bigger => lines.any((line) => line.bigger);
  bool get pattern => lines.any((line) => line.pattern);
  PdfOutlineEntry? get outlineEntry =>
      lines.map((line) => line.outline).nonNulls.firstOrNull;
  double get size => lines.map((line) => line.line.size).reduce(math.max);

  String get text {
    if (lines.length == 1) return first.line.text.trim();
    final head = first.line.text.trim();
    final rest = lines.skip(1).map((line) => line.line.text.trim()).join(' ');
    if (PdfTextAnalyzer._bareChapterLabel.hasMatch(head)) {
      return '${head.replaceFirst(RegExp(r'\.$'), '')}: $rest';
    }
    return '$head $rest';
  }
}

class _SplitRule {
  const _SplitRule({required this.level, this.useOutline = false});

  /// Headings at this level or more prominent start a chapter. 0 = never.
  final int level;
  final bool useOutline;

  bool splits(_Item item, int itemLevel) {
    if (useOutline) {
      final entry = item.outlineEntry;
      return entry != null && entry.level == 0;
    }
    return level > 0 && itemLevel <= level;
  }

  int relativeLevel(int itemLevel) {
    if (useOutline) return (itemLevel).clamp(1, 3);
    if (level == 0) return itemLevel.clamp(1, 3);
    return (itemLevel - level + 1).clamp(2, 3);
  }
}

/// Collects lines of one paragraph and joins them.
class _ParagraphBuilder {
  final _lines = <_Line>[];

  bool get isEmpty => _lines.isEmpty;

  void add(_Line line) => _lines.add(line);

  ParagraphBlock? build() {
    if (_lines.isEmpty) return null;
    final texts = [for (final line in _lines) line.line.text.trim()];
    final verse = _isVerse();
    final text = joinLines(texts);
    _lines.clear();
    if (text.isEmpty) return null;
    // A stray page number or OCR speck rather than text.
    if (text.length <= 6 && !PdfTextAnalyzer._letter.hasMatch(text)) {
      return null;
    }
    return ParagraphBlock(text, lines: verse ? texts : null);
  }

  /// Several short, flush lines in a row read as verse or a list.
  bool _isVerse() {
    if (_lines.length < 3) return false;
    var short = 0;
    for (final line in _lines.take(_lines.length - 1)) {
      final width = math.max(line.colRight - line.colLeft, 1.0);
      if (line.line.width < width * 0.7) short++;
    }
    return short >= (_lines.length - 1) * 0.75;
  }

  static final _hyphenEnd = RegExp(r'\p{L}[-‐]$', unicode: true);
  static final _lowerStart = RegExp(r'^\p{Ll}', unicode: true);

  /// Joins wrapped lines, removing hyphens added at line breaks.
  static String joinLines(List<String> lines) {
    final buffer = StringBuffer();
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (buffer.isEmpty) {
        buffer.write(line);
        continue;
      }
      final current = buffer.toString();
      if (_hyphenEnd.hasMatch(current)) {
        if (_lowerStart.hasMatch(line)) {
          buffer
            ..clear()
            ..write(current.substring(0, current.length - 1))
            ..write(line);
        } else {
          buffer.write(line);
        }
      } else if (current.endsWith('—') || current.endsWith('/')) {
        buffer.write(line);
      } else {
        buffer
          ..write(' ')
          ..write(line);
      }
    }
    return buffer.toString();
  }
}

/// Exposed for tests.
String joinPdfLines(List<String> lines) => _ParagraphBuilder.joinLines(lines);
