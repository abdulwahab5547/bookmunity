import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'book_content.dart';
import 'epub_writer.dart';
import 'pdf_info_reader.dart';
import 'pdf_layout.dart';
import 'pdf_line_builder.dart';
import 'pdf_text_analyzer.dart';

/// Everything extracted from a PDF, ready to become an EPUB. Plain data, so
/// it can be sent to a background isolate.
class PdfExtraction {
  const PdfExtraction({
    required this.pages,
    required this.outline,
    required this.info,
    required this.fingerprint,
    this.filename,
    this.coverJpeg,
    this.pageImages = const {},
    this.scanned = false,
  });

  final List<PdfRawPageText> pages;
  final List<PdfOutlineEntry> outline;
  final PdfInfo info;

  /// Hex digest of the PDF bytes, used for a stable identifier.
  final String fingerprint;
  final String? filename;
  final Uint8List? coverJpeg;
  final Map<int, Uint8List> pageImages;
  final bool scanned;
}

class PdfEpubBuildResult {
  const PdfEpubBuildResult({
    required this.epub,
    required this.title,
    required this.chapterCount,
  });

  final Uint8List epub;
  final String title;
  final int chapterCount;
}

/// Pure-Dart half of the PDF converter: text heuristics and EPUB writing.
class PdfEpubBuilder {
  const PdfEpubBuilder();

  /// Pages with fewer visible characters than this count as image pages.
  static const textPageMinimum = 20;

  static int visibleCharacters(String text) =>
      text.replaceAll(RegExp(r'\s'), '').length;

  /// A PDF is treated as scanned when most of its pages carry no text layer.
  static bool looksScanned(List<int> charactersPerPage) {
    if (charactersPerPage.isEmpty) return true;
    final textPages = charactersPerPage
        .where((count) => count >= textPageMinimum)
        .length;
    return textPages < charactersPerPage.length * 0.5;
  }

  static String fingerprintOf(List<int> bytes) =>
      sha256.convert(bytes).toString();

  PdfEpubBuildResult build(PdfExtraction source) {
    final title =
        source.info.title ?? PdfInfoReader.titleFromFilename(source.filename);
    final author = source.info.author ?? '';
    final chapters = source.scanned
        ? _scannedChapters(source)
        : _textChapters(source);
    final epub = const EpubWriter().write(
      EpubBookData(
        title: title,
        author: author,
        identifier: identifierFor(source.fingerprint),
        language: _language(source.info.language),
        chapters: chapters,
        coverJpeg: source.coverJpeg,
        pageImages: source.pageImages,
        source: source.filename,
      ),
    );
    return PdfEpubBuildResult(
      epub: epub,
      title: title,
      chapterCount: chapters.length,
    );
  }

  /// An identifier without digits, so the metadata extractor never mistakes
  /// it for an ISBN.
  static String identifierFor(String fingerprint) {
    final letters = fingerprint
        .substring(0, fingerprint.length.clamp(0, 32))
        .split('')
        .map((char) {
          final value = int.tryParse(char, radix: 16) ?? 0;
          return String.fromCharCode(0x61 + value);
        })
        .join();
    return 'urn:bookmunity:pdf:$letters';
  }

  String _language(String? value) {
    final language = value?.trim() ?? '';
    if (RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(language)) {
      return language;
    }
    return 'en';
  }

  List<BookChapter> _textChapters(PdfExtraction source) {
    const builder = PdfLineBuilder();
    final layouts = [for (final page in source.pages) builder.build(page)];
    final analysis = const PdfTextAnalyzer().analyze(
      layouts,
      outline: source.outline,
    );
    return analysis.chapters;
  }

  List<BookChapter> _scannedChapters(PdfExtraction source) {
    final outlineStarts = <int, String>{};
    for (final entry in source.outline) {
      final page = entry.pageNumber;
      if (page != null && entry.level == 0) {
        outlineStarts.putIfAbsent(page, () => entry.title);
      }
    }
    final pages = source.pages.map((page) => page.pageNumber).toList();
    return [
      for (final page in pages)
        BookChapter(
          title: outlineStarts[page] ?? 'Page $page',
          blocks: [PageImageBlock(page)],
          listed: outlineStarts.isNotEmpty
              ? outlineStarts.containsKey(page) || page == pages.first
              : page == pages.first || page % 10 == 0,
        ),
    ];
  }
}
