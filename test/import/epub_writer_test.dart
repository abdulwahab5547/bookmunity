import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bookmunity/core/import/epub_metadata_extractor.dart';
import 'package:bookmunity/core/import/pdf/book_content.dart';
import 'package:bookmunity/core/import/pdf/epub_writer.dart';
import 'package:bookmunity/core/import/pdf/pdf_epub_builder.dart';
import 'package:bookmunity/core/import/pdf/pdf_info_reader.dart';
import 'package:bookmunity/core/import/pdf/pdf_layout.dart';
import 'package:bookmunity/core/import/pdf/pdf_line_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

List<int> _jpeg() => img.encodeJpg(img.Image(width: 30, height: 45));

String _text(Archive archive, String name) =>
    utf8.decode(archive.files.firstWhere((file) => file.name == name).content);

void main() {
  group('EpubWriter', () {
    final bytes = const EpubWriter().write(
      EpubBookData(
        title: 'Tom & Jerry <The Book>',
        author: 'Ada Marlowe',
        identifier: PdfEpubBuilder.identifierFor('0123456789abcdef' * 4),
        coverJpeg: _jpeg(),
        pageImages: {3: _jpeg()},
        chapters: const [
          BookChapter(
            title: 'Chapter 1',
            blocks: [
              HeadingBlock('Chapter 1'),
              ParagraphBlock('It was a dark & stormy "night".'),
              ParagraphBlock('Fool!', lines: ['Fool! All that is', 'at all']),
              PageImageBlock(3),
              PageImageBlock(4), // no image: left out
            ],
          ),
          BookChapter(
            title: 'Chapter 2',
            blocks: [HeadingBlock('A section', level: 2)],
          ),
        ],
      ),
    );
    final archive = ZipDecoder().decodeBytes(bytes);

    test('starts with an uncompressed mimetype entry', () {
      // Local file header: name at offset 30, data straight after it.
      expect(latin1.decode(bytes.sublist(30, 38)), 'mimetype');
      expect(latin1.decode(bytes.sublist(38, 58)), 'application/epub+zip');
      expect(archive.files.first.name, 'mimetype');
    });

    test('is read by the app metadata extractor', () {
      final metadata = const EpubMetadataExtractor().extract(archive);
      expect(metadata.title, 'Tom & Jerry <The Book>');
      expect(metadata.author, 'Ada Marlowe');
      expect(metadata.bookKey, 'tom-jerry-the-book|ada-marlowe');
      expect(metadata.coverBytes, isNotNull);
    });

    test('identifier never looks like an ISBN', () {
      final id = PdfEpubBuilder.identifierFor('9780141439518000' * 4);
      expect(id.replaceAll(RegExp(r'[^0-9Xx]'), ''), isEmpty);
    });

    test('writes well-formed XHTML, nav and NCX', () {
      for (final file in archive.files) {
        if (file.name.endsWith('.xhtml') ||
            file.name.endsWith('.opf') ||
            file.name.endsWith('.ncx') ||
            file.name.endsWith('.xml')) {
          expect(
            () => XmlDocument.parse(utf8.decode(file.content)),
            returnsNormally,
            reason: file.name,
          );
        }
      }
      final nav = _text(archive, 'OEBPS/nav.xhtml');
      expect(nav, contains('epub:type="toc"'));
      expect(RegExp('<li>').allMatches(nav), hasLength(2));
      final opf = _text(archive, 'OEBPS/content.opf');
      expect(opf, contains('properties="nav"'));
      expect(opf, contains('properties="cover-image"'));
      expect(opf, contains('dcterms:modified'));
    });

    test('renders blocks, escaping text and keeping verse lines', () {
      final chapter = _text(archive, 'OEBPS/text/c0001.xhtml');
      expect(chapter, contains('<h1>Chapter 1</h1>'));
      expect(chapter, contains('dark &amp; stormy &quot;night&quot;'));
      expect(chapter, contains('Fool! All that is<br/>at all'));
      expect(chapter, contains('../images/page-0003.jpg'));
      expect(chapter, isNot(contains('page-0004')));
      expect(
        archive.files.map((file) => file.name),
        contains('OEBPS/images/page-0003.jpg'),
      );
    });

    test('splits very long chapters into several files', () {
      final long = const EpubWriter().write(
        EpubBookData(
          title: 'Long',
          author: '',
          identifier: 'urn:x',
          chapters: [
            BookChapter(
              title: 'One',
              blocks: [
                for (var i = 0; i < 300; i++) ParagraphBlock('x' * 1000),
              ],
            ),
          ],
        ),
      );
      final files = ZipDecoder()
          .decodeBytes(long)
          .files
          .where((file) => file.name.startsWith('OEBPS/text/'));
      expect(files.length, greaterThan(2));
      final nav = _text(ZipDecoder().decodeBytes(long), 'OEBPS/nav.xhtml');
      expect(RegExp('<li>').allMatches(nav), hasLength(1));
    });
  });

  group('PdfEpubBuilder', () {
    test('treats PDFs without a text layer as scanned', () {
      expect(PdfEpubBuilder.looksScanned([0, 0, 0, 5]), isTrue);
      expect(PdfEpubBuilder.looksScanned([900, 1200, 0, 1100]), isFalse);
    });

    test('a scanned PDF becomes one image page per PDF page', () {
      final result = const PdfEpubBuilder().build(
        PdfExtraction(
          pages: [
            for (var n = 1; n <= 12; n++)
              PdfRawPageText(
                pageNumber: n,
                width: 595,
                height: 842,
                text: '',
                rects: Float64List(0),
              ),
          ],
          outline: const [],
          info: const PdfInfo(),
          fingerprint: 'abc',
          filename: 'old_scan.pdf',
          scanned: true,
          pageImages: {
            for (var n = 1; n <= 12; n++) n: Uint8List.fromList(_jpeg()),
          },
        ),
      );
      final archive = ZipDecoder().decodeBytes(result.epub);
      expect(result.title, 'Old Scan');
      expect(
        archive.files.where(
          (file) => file.name.startsWith('OEBPS/images/page-'),
        ),
        hasLength(12),
      );
      final nav = _text(archive, 'OEBPS/nav.xhtml');
      // First page and every tenth page are listed.
      expect(RegExp('<li>').allMatches(nav), hasLength(2));
      final metadata = const EpubMetadataExtractor().extract(archive);
      expect(metadata.title, 'Old Scan');
    });
  });

  group('PdfLineBuilder', () {
    test('splits a two-column page and reads it column by column', () {
      // Real PDFium output for a reportlab two-column page whose words are
      // numbered seq0001, seq0002, …
      final json =
          jsonDecode(
                File(
                  'test/fixtures/pdf/two_column_page_raw.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final raw = PdfRawPageText(
        pageNumber: json['pageNumber'] as int,
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        text: json['text'] as String,
        rects: Float64List.fromList(
          (json['rects'] as List).map((v) => (v as num).toDouble()).toList(),
        ),
      );
      final layout = const PdfLineBuilder().build(raw);
      final numbers = [
        for (final line in layout.lines)
          for (final match in RegExp(r'seq(\d{4})').allMatches(line.text))
            int.parse(match[1]!),
      ];
      expect(numbers, isNotEmpty);
      for (var i = 1; i < numbers.length; i++) {
        expect(numbers[i], numbers[i - 1] + 1, reason: 'at token $i');
      }
      // No line spans both columns.
      expect(
        layout.lines.where((line) => line.width > raw.width * 0.6),
        isEmpty,
      );
    });

    test('estimates font size from glyph heights', () {
      // Capitals are about 0.7 em tall.
      expect(
        PdfLineBuilder.estimateSize(['T', 'h', 'e'], [7.7, 7.7, 5.5]),
        closeTo(11, 0.5),
      );
    });
  });

  group('PdfInfoReader', () {
    test('reads title and author from a real reportlab PDF', () {
      final info = const PdfInfoReader().read(
        File('test/fixtures/pdf/lighthouse_keeper.pdf').readAsBytesSync(),
      );
      expect(info.title, 'The Lighthouse Keeper');
      expect(info.author, 'Ada Marlowe');
    });

    test('decodes escapes, UTF-16 hex strings and XMP', () {
      final pdf = latin1.encode(
        '%PDF-1.4\n1 0 obj << /Title (Caf\\351 \\(Paris\\)) '
        '/Author <FEFF00C9006D0069006C0065> >> endobj\n',
      );
      final info = const PdfInfoReader().read(pdf);
      expect(info.title, 'Café (Paris)');
      expect(info.author, 'Émile');

      final xmp = utf8.encode(
        '%PDF-1.7\n<x:xmpmeta><dc:title><rdf:Alt><rdf:li xml:lang="x-default">'
        'Ünïcode Title</rdf:li></rdf:Alt></dc:title></x:xmpmeta>',
      );
      expect(const PdfInfoReader().read(xmp).title, 'Ünïcode Title');
    });

    test('finds the info dictionary inside a compressed object stream', () {
      final inner = ZLibEncoder().encode(
        latin1.encode('<< /Title (Hidden Title) /Author (Someone) >>'),
      );
      final pdf = <int>[
        ...latin1.encode(
          '%PDF-1.5\n5 0 obj << /Type /ObjStm /N 1 /First 4 '
          '/Filter /FlateDecode /Length ${inner.length} >>\nstream\n',
        ),
        ...inner,
        ...latin1.encode('\nendstream\nendobj\n'),
      ];
      final info = const PdfInfoReader().read(pdf);
      expect(info.title, 'Hidden Title');
      expect(info.author, 'Someone');
    });

    test('ignores junk titles and falls back to the file name', () {
      expect(PdfInfoReader.cleanTitle('untitled'), isNull);
      expect(
        PdfInfoReader.cleanTitle('Microsoft Word - Thesis.docx'),
        'Thesis',
      );
      expect(PdfInfoReader.cleanTitle('scan_0042'), isNull);
      expect(
        PdfInfoReader.titleFromFilename('/x/the_time-machine (1).pdf'),
        'The Time Machine',
      );
    });
  });
}
