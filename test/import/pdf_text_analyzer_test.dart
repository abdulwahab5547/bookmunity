import 'dart:convert';
import 'dart:io';

import 'package:bookmunity/core/import/pdf/book_content.dart';
import 'package:bookmunity/core/import/pdf/pdf_layout.dart';
import 'package:bookmunity/core/import/pdf/pdf_text_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lays out lines top-down on an A4 page, like a simple PDF writer would.
class _PageBuilder {
  _PageBuilder(this.pageNumber);

  final int pageNumber;
  final lines = <PdfTextLine>[];
  double y = 780;

  void header(String text) => lines.add(_line(text, 250, 806, size: 9));

  void footer(String text) => lines.add(_line(text, 295, 36, size: 9));

  void heading(String text, {double size = 18, double gapAfter = 20}) {
    lines.add(_line(text, 60, y, size: size));
    y -= size + gapAfter;
  }

  /// Body lines; the first is indented and the last is short.
  void paragraph(List<String> text, {bool indent = true, bool fullLast = false}) {
    for (var i = 0; i < text.length; i++) {
      final last = i == text.length - 1;
      final left = indent && i == 0 ? 78.0 : 60.0;
      final right = last && !fullLast ? 300.0 : 535.0;
      lines.add(_line(text[i], left, y, size: 11, right: right));
      y -= 15;
    }
  }

  PdfPageLayout build() => PdfPageLayout(
    pageNumber: pageNumber,
    width: 595,
    height: 842,
    lines: List.of(lines),
  );

  static PdfTextLine _line(
    String text,
    double left,
    double top, {
    required double size,
    double? right,
  }) => PdfTextLine(
    text: text,
    left: left,
    top: top,
    right: right ?? left + text.length * size * 0.5,
    bottom: top - size,
    size: size,
  );
}

const _vocabulary = [
  'keeper', 'harbour', 'lantern', 'stone', 'merchant', 'corridor', 'waves',
  'northward', 'ancient', 'silent', 'burning', 'stories', 'rocks', 'night',
];

const _digits = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine',
];

/// Digits as words, so lines never differ only by numbers (which the
/// running-header detector deliberately ignores).
String _spell(String value) => value.replaceAllMapped(
  RegExp(r'\d'),
  (match) => _digits[int.parse(match[0]!)],
);

/// Distinct, realistic body lines: "[prefix] keeper harbour lantern …".
List<String> _words(String prefix, int count) => [
  for (var i = 0; i < count; i++)
    '${_spell(prefix)} ${_spell('$i')} ${[for (var w = 0; w < 6; w++) _vocabulary[(prefix.hashCode + i * 5 + w * 3) % _vocabulary.length]].join(' ')}',
];

void main() {
  const analyzer = PdfTextAnalyzer();

  group('joinPdfLines', () {
    test('removes hyphens added at line breaks', () {
      expect(
        joinPdfLines(['The keeper walked north-', 'ward along the shore.']),
        'The keeper walked northward along the shore.',
      );
    });

    test('keeps hyphens of compound words before capitals', () {
      expect(
        joinPdfLines(['an Anglo-', 'Saxon king']),
        'an Anglo-Saxon king',
      );
    });

    test('joins plain lines with one space and keeps dashes tight', () {
      expect(joinPdfLines(['one  ', ' two']), 'one two');
      expect(joinPdfLines(['wait—', 'then']), 'wait—then');
    });
  });

  group('page furniture', () {
    test('drops running headers and page numbers but keeps big titles', () {
      final pages = <PdfPageLayout>[];
      for (var n = 1; n <= 5; n++) {
        final page = _PageBuilder(n)
          ..header('THE LIGHTHOUSE KEEPER')
          ..footer('$n');
        if (n == 3) page.heading('Chapter 2', size: 18);
        page.paragraph(_words('Page $n', 6));
        pages.add(page.build());
      }
      final cleaned = analyzer.removePageFurniture(pages);
      final texts = [
        for (final page in cleaned)
          for (final line in page.lines) line.text,
      ];
      expect(texts, isNot(contains('THE LIGHTHOUSE KEEPER')));
      expect(texts.where((t) => RegExp(r'^\d+$').hasMatch(t)), isEmpty);
      expect(texts, contains('Chapter 2'));
      expect(texts, contains(_words('Page 1', 6).first));
    });

    test('a header with the page number in it still counts as repeated', () {
      final pages = [
        for (var n = 10; n < 14; n++)
          (_PageBuilder(n)
                ..header('$n  THE TIME MACHINE')
                ..paragraph(_words('p$n', 4)))
              .build(),
      ];
      final cleaned = analyzer.removePageFurniture(pages);
      expect(
        cleaned.expand((page) => page.lines).map((line) => line.text),
        everyElement(isNot(contains('TIME MACHINE'))),
      );
    });
  });

  group('headings and chapters', () {
    test('splits chapters at "Chapter" headings and keeps subheadings', () {
      final pages = [
        (_PageBuilder(1)..heading('The Lighthouse Keeper', size: 30)).build(),
        (_PageBuilder(2)
              ..heading('Chapter 1')
              ..paragraph(_words('One', 4))
              ..heading('A smaller section', size: 14)
              ..paragraph(_words('Two', 3)))
            .build(),
        (_PageBuilder(3)
              ..heading('Chapter 2')
              ..paragraph(_words('Three', 5)))
            .build(),
      ];
      final chapters = analyzer.analyze(pages).chapters;
      expect(chapters.map((c) => c.title), [
        'The Lighthouse Keeper',
        'Chapter 1',
        'Chapter 2',
      ]);
      final first = chapters[1].blocks;
      expect(first.first, isA<HeadingBlock>());
      expect((first.first as HeadingBlock).level, 1);
      final sub = first.whereType<HeadingBlock>().last;
      expect(sub.text, 'A smaller section');
      expect(sub.level, greaterThan(1));
      expect(first.whereType<ParagraphBlock>(), hasLength(2));
    });

    test('merges "CHAPTER IV" with the chapter name below it', () {
      final pages = [
        for (var n = 1; n <= 2; n++)
          (_PageBuilder(n)
                ..heading(n == 1 ? 'CHAPTER IV' : 'CHAPTER V', size: 16, gapAfter: 8)
                ..heading(n == 1 ? 'The Golden Age' : 'Sunset', size: 16)
                ..paragraph(_words('Body $n', 4)))
              .build(),
      ];
      final titles = analyzer.analyze(pages).chapters.map((c) => c.title);
      expect(titles, ['CHAPTER IV: The Golden Age', 'CHAPTER V: Sunset']);
    });

    test('uses PDF bookmarks for chapters when present', () {
      final pages = [
        for (var n = 1; n <= 4; n++)
          (_PageBuilder(n)..paragraph(_words('Text $n', 5))).build(),
      ];
      final chapters = analyzer
          .analyze(
            pages,
            outline: const [
              PdfOutlineEntry(title: 'Opening', pageNumber: 1, level: 0),
              PdfOutlineEntry(title: 'Middle', pageNumber: 3, level: 0),
            ],
          )
          .chapters;
      expect(chapters.map((c) => c.title), ['Opening', 'Middle']);
      expect(
        (chapters[1].blocks.whereType<ParagraphBlock>().first).text,
        startsWith(_words('Text 3', 5).first),
      );
    });

    test('ignores OCR noise and sentence fragments set in large type', () {
      expect(PdfTextAnalyzer.looksLikeHeading('NOV 2 5 1994'), isFalse);
      expect(PdfTextAnalyzer.looksLikeHeading('m 1,993'), isFalse);
      expect(PdfTextAnalyzer.looksLikeHeading('never convince me."'), isFalse);
      expect(PdfTextAnalyzer.looksLikeHeading('The Golden Age'), isTrue);
      expect(PdfTextAnalyzer.looksLikeHeading('CHAPTER I.'), isTrue);
    });

    test('falls back to parts when a long PDF has no structure', () {
      final pages = [
        for (var n = 1; n <= 30; n++)
          () {
            final page = _PageBuilder(n);
            for (var k = 0; k < 5; k++) {
              page.paragraph(_words('Plain $n $k', 8));
            }
            return page.build();
          }(),
      ];
      final chapters = analyzer.analyze(pages).chapters;
      expect(chapters.length, greaterThan(1));
      expect(chapters.first.title, 'Part 1');
    });
  });

  group('paragraphs', () {
    test('breaks at indents and joins lines within a paragraph', () {
      final page = _PageBuilder(1)
        ..paragraph(['First paragraph starts', 'and keeps going here.'])
        ..paragraph(['Second paragraph starts', 'and ends here.']);
      final blocks = analyzer.analyze([page.build()]).chapters.single.blocks;
      expect(blocks.whereType<ParagraphBlock>().map((p) => p.text), [
        'First paragraph starts and keeps going here.',
        'Second paragraph starts and ends here.',
      ]);
    });

    test('breaks at a larger vertical gap between flush paragraphs', () {
      final page = _PageBuilder(1)
        ..paragraph(['Block one line one', 'block one line two.'], indent: false)
        ..y -= 14
        ..paragraph(['Block two line one', 'block two line two.'], indent: false);
      final blocks = analyzer.analyze([page.build()]).chapters.single.blocks;
      expect(blocks.whereType<ParagraphBlock>(), hasLength(2));
    });

    test('continues a sentence across a page break', () {
      final one = _PageBuilder(1)
        ..paragraph(['The keeper climbed the', 'stairs and looked out over'], fullLast: true);
      final two = _PageBuilder(2)
        ..paragraph(['the dark water below.', 'Nobody answered.'], indent: false);
      final blocks = analyzer
          .analyze([one.build(), two.build()])
          .chapters
          .single
          .blocks;
      expect(
        blocks.whereType<ParagraphBlock>().first.text,
        'The keeper climbed the stairs and looked out over the dark water '
        'below. Nobody answered.',
      );
    });

    test('keeps line breaks for verse', () {
      final page = _PageBuilder(1);
      for (final verse in ['Fool! All that is', 'at all lasts ever', 'past recall', 'said he']) {
        page.lines.add(
          PdfTextLine(
            text: verse,
            left: 60,
            top: page.y,
            right: 200,
            bottom: page.y - 11,
            size: 11,
          ),
        );
        page.y -= 15;
      }
      page.paragraph(_words('Prose', 3));
      final blocks = analyzer.analyze([page.build()]).chapters.single.blocks;
      final verse = blocks.whereType<ParagraphBlock>().first;
      expect(verse.lines, hasLength(4));
    });
  });

  test('cleans a real OCR scan (The Time Machine, archive.org)', () {
    final json =
        jsonDecode(
              File(
                'test/fixtures/pdf/time_machine_pages_13_22_lines.json',
              ).readAsStringSync(),
            )
            as List;
    final pages = [
      for (final page in json.cast<Map<String, dynamic>>())
        PdfPageLayout(
          pageNumber: page['pageNumber'] as int,
          width: (page['width'] as num).toDouble(),
          height: (page['height'] as num).toDouble(),
          lines: [
            for (final line in (page['lines'] as List).cast<List>())
              PdfTextLine(
                text: line[0] as String,
                left: (line[1] as num).toDouble(),
                top: (line[2] as num).toDouble(),
                right: (line[3] as num).toDouble(),
                bottom: (line[4] as num).toDouble(),
                size: (line[5] as num).toDouble(),
              ),
          ],
        ),
    ];
    final paragraphs = analyzer
        .analyze(pages)
        .chapters
        .expand((chapter) => chapter.blocks)
        .whereType<ParagraphBlock>()
        .map((p) => p.text)
        .toList();
    final text = paragraphs.join('\n');
    expect(text, isNot(contains('THE TIME MACHINE.')));
    expect(text, isNot(contains('THE INVENTOR.')));
    expect(paragraphs, isNot(contains('lO')));
    // Hyphenated words across lines are rejoined.
    expect(text, contains('Psychologist'));
    expect(text, isNot(contains('Psycholo- gist')));
    expect(paragraphs.length, greaterThan(20));
  });
}
