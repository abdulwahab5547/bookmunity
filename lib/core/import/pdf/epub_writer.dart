import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_content.dart';

/// Everything needed to write a converted book.
class EpubBookData {
  const EpubBookData({
    required this.title,
    required this.author,
    required this.identifier,
    required this.chapters,
    this.language = 'en',
    this.coverJpeg,
    this.pageImages = const {},
    this.modified,
    this.source,
  });

  final String title;

  /// Empty when unknown.
  final String author;

  /// Stable identifier, e.g. `urn:sha256:…` of the source PDF.
  final String identifier;
  final String language;
  final List<BookChapter> chapters;
  final List<int>? coverJpeg;

  /// JPEG bytes for [PageImageBlock]s, by page number. Blocks without an
  /// image are left out.
  final Map<int, List<int>> pageImages;
  final DateTime? modified;

  /// Where the book came from, e.g. the original file name.
  final String? source;
}

/// Writes a valid EPUB 3 (with an EPUB 2 NCX for older readers).
class EpubWriter {
  const EpubWriter();

  /// Chapters longer than this many characters are split into several
  /// files so the reader never lays out one huge document.
  static const maxFileCharacters = 120000;

  Uint8List write(EpubBookData book) {
    final archive = Archive();
    final mimetype = utf8.encode('application/epub+zip');
    // The mimetype entry must come first and be stored uncompressed.
    archive.add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));
    archive.add(ArchiveFile.string('META-INF/container.xml', _container));
    archive.add(ArchiveFile.string('OEBPS/style.css', _css));

    final manifest = <_ManifestItem>[];
    final spine = <String>[];
    final toc = <_TocEntry>[];

    if (book.coverJpeg != null) {
      archive.add(ArchiveFile.bytes('OEBPS/images/cover.jpg', book.coverJpeg!));
      manifest.add(
        const _ManifestItem(
          'cover-image',
          'images/cover.jpg',
          'image/jpeg',
          properties: 'cover-image',
        ),
      );
      archive.add(
        ArchiveFile.string(
          'OEBPS/cover.xhtml',
          _document(
            book.title,
            book.language,
            '<section epub:type="cover" class="cover">'
            '<img src="images/cover.jpg" alt="${escapeXml(book.title)}"/>'
            '</section>',
            cssHref: 'style.css',
          ),
        ),
      );
      manifest.add(
        const _ManifestItem('cover', 'cover.xhtml', 'application/xhtml+xml'),
      );
      spine.add('cover');
    }

    final usedImages = <int>{};
    var fileIndex = 0;
    for (final chapter in book.chapters) {
      final parts = _splitBlocks(chapter.blocks);
      for (var part = 0; part < parts.length; part++) {
        fileIndex++;
        final id = 'c${fileIndex.toString().padLeft(4, '0')}';
        final href = 'text/$id.xhtml';
        final body = StringBuffer();
        for (final block in parts[part]) {
          switch (block) {
            case HeadingBlock(:final text, :final level):
              final tag = 'h${level.clamp(1, 3)}';
              body.write('<$tag>${escapeXml(text)}</$tag>\n');
            case ParagraphBlock(:final text, :final lines):
              if (lines != null && lines.length > 1) {
                body.write(
                  '<p class="lines">'
                  '${lines.map(escapeXml).join('<br/>')}</p>\n',
                );
              } else {
                body.write('<p>${escapeXml(text)}</p>\n');
              }
            case PageImageBlock(:final pageNumber):
              if (!book.pageImages.containsKey(pageNumber)) continue;
              usedImages.add(pageNumber);
              // The caption is real text, which the reader needs to place
              // reading positions; image-only pages would have none.
              body.write(
                '<div class="page-image"><img src="../${_imageHref(pageNumber)}" '
                'alt="Page $pageNumber"/>'
                '<p class="page-caption">Page $pageNumber</p></div>\n',
              );
          }
        }
        if (body.isEmpty) {
          // Keep the file valid and the TOC target reachable.
          body.write('<p></p>');
        }
        archive.add(
          ArchiveFile.string(
            'OEBPS/$href',
            _document(chapter.title, book.language, body.toString()),
          ),
        );
        manifest.add(_ManifestItem(id, href, 'application/xhtml+xml'));
        spine.add(id);
        if (part == 0 && chapter.listed) {
          toc.add(_TocEntry(chapter.title, href));
        }
      }
    }

    for (final page in usedImages.toList()..sort()) {
      archive.add(
        ArchiveFile.bytes('OEBPS/${_imageHref(page)}', book.pageImages[page]!),
      );
      manifest.add(_ManifestItem('p$page', _imageHref(page), 'image/jpeg'));
    }

    if (toc.isEmpty && spine.isNotEmpty) {
      final first = manifest.firstWhere((item) => item.id == spine.first);
      toc.add(_TocEntry(book.title, first.href));
    }

    archive.add(ArchiveFile.string('OEBPS/nav.xhtml', _nav(book, toc)));
    archive.add(ArchiveFile.string('OEBPS/toc.ncx', _ncx(book, toc)));
    archive.add(
      ArchiveFile.string('OEBPS/content.opf', _opf(book, manifest, spine)),
    );

    return ZipEncoder().encodeBytes(archive);
  }

  static String _imageHref(int page) =>
      'images/page-${page.toString().padLeft(4, '0')}.jpg';

  List<List<BookBlock>> _splitBlocks(List<BookBlock> blocks) {
    final parts = <List<BookBlock>>[[]];
    var length = 0;
    for (final block in blocks) {
      final size = switch (block) {
        ParagraphBlock(:final text) => text.length,
        HeadingBlock(:final text) => text.length,
        PageImageBlock() => 4000,
      };
      if (length + size > maxFileCharacters && parts.last.isNotEmpty) {
        parts.add([]);
        length = 0;
      }
      parts.last.add(block);
      length += size;
    }
    return parts;
  }

  static final _invalidXml = RegExp(
    '[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]',
  );

  static String escapeXml(String value) => value
      .replaceAll(_invalidXml, '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String _document(
    String title,
    String language,
    String body, {
    String cssHref = '../style.css',
  }) =>
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops" '
      'xml:lang="${escapeXml(language)}" lang="${escapeXml(language)}">\n'
      '<head>\n<meta charset="utf-8"/>\n'
      '<title>${escapeXml(title)}</title>\n'
      '<link rel="stylesheet" type="text/css" href="$cssHref"/>\n'
      '</head>\n<body>\n$body</body>\n</html>\n';

  String _opf(
    EpubBookData book,
    List<_ManifestItem> manifest,
    List<String> spine,
  ) {
    final modified = (book.modified ?? DateTime.now())
        .toUtc()
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    final items = StringBuffer()
      ..writeln(
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>',
      )
      ..writeln(
        '    <item id="ncx" href="toc.ncx" '
        'media-type="application/x-dtbncx+xml"/>',
      )
      ..writeln('    <item id="css" href="style.css" media-type="text/css"/>');
    for (final item in manifest) {
      items.writeln(
        '    <item id="${item.id}" href="${escapeXml(item.href)}" '
        'media-type="${item.mediaType}"'
        '${item.properties == null ? '' : ' properties="${item.properties}"'}/>',
      );
    }
    final refs = spine.map((id) => '    <itemref idref="$id"/>').join('\n');
    final creator = book.author.trim().isEmpty
        ? ''
        : '    <dc:creator id="creator">${escapeXml(book.author)}</dc:creator>\n';
    final source = book.source == null
        ? ''
        : '    <dc:source>${escapeXml(book.source!)}</dc:source>\n';
    final cover = book.coverJpeg == null
        ? ''
        : '    <meta name="cover" content="cover-image"/>\n';
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="book-id" xml:lang="${escapeXml(book.language)}">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '    <dc:identifier id="book-id">${escapeXml(book.identifier)}</dc:identifier>\n'
        '    <dc:title>${escapeXml(book.title)}</dc:title>\n'
        '$creator'
        '    <dc:language>${escapeXml(book.language)}</dc:language>\n'
        '$source'
        '    <meta property="dcterms:modified">$modified</meta>\n'
        '$cover'
        '  </metadata>\n'
        '  <manifest>\n$items  </manifest>\n'
        '  <spine toc="ncx">\n$refs\n  </spine>\n'
        '</package>\n';
  }

  String _nav(EpubBookData book, List<_TocEntry> toc) {
    final items = toc
        .map(
          (entry) =>
              '      <li><a href="${escapeXml(entry.href)}">'
              '${escapeXml(entry.title)}</a></li>',
        )
        .join('\n');
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops" '
        'xml:lang="${escapeXml(book.language)}">\n'
        '<head><meta charset="utf-8"/><title>${escapeXml(book.title)}</title></head>\n'
        '<body>\n'
        '  <nav epub:type="toc" id="toc">\n'
        '    <h1>Contents</h1>\n'
        '    <ol>\n$items\n    </ol>\n'
        '  </nav>\n'
        '</body>\n</html>\n';
  }

  String _ncx(EpubBookData book, List<_TocEntry> toc) {
    final points = StringBuffer();
    for (var i = 0; i < toc.length; i++) {
      points.writeln(
        '    <navPoint id="np${i + 1}" playOrder="${i + 1}">'
        '<navLabel><text>${escapeXml(toc[i].title)}</text></navLabel>'
        '<content src="${escapeXml(toc[i].href)}"/></navPoint>',
      );
    }
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '  <head><meta name="dtb:uid" content="${escapeXml(book.identifier)}"/></head>\n'
        '  <docTitle><text>${escapeXml(book.title)}</text></docTitle>\n'
        '  <navMap>\n$points  </navMap>\n'
        '</ncx>\n';
  }

  static const _container =
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
      '  <rootfiles>\n'
      '    <rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/>\n'
      '  </rootfiles>\n'
      '</container>\n';

  static const _css = '''
body { margin: 0; padding: 0; }
h1, h2, h3 { line-height: 1.25; text-align: left; page-break-after: avoid; break-after: avoid; }
h1 { font-size: 1.5em; margin: 1.2em 0 0.8em; }
h2 { font-size: 1.25em; margin: 1.1em 0 0.6em; }
h3 { font-size: 1.1em; margin: 1em 0 0.5em; }
p { margin: 0 0 0.2em; text-indent: 1.2em; text-align: justify; }
h1 + p, h2 + p, h3 + p, .page-image + p { text-indent: 0; }
p.lines { text-indent: 0; text-align: left; margin: 0.6em 0; }
.page-image { text-align: center; margin: 0.5em 0; page-break-inside: avoid; break-inside: avoid; }
.page-image img { max-width: 100%; max-height: 90vh; }
.page-image p.page-caption { text-indent: 0; text-align: center; font-size: 0.75em; opacity: 0.6; margin: 0.3em 0 0; }
.cover { text-align: center; margin: 0; padding: 0; }
.cover img { max-width: 100%; max-height: 98vh; }
''';
}

class _ManifestItem {
  const _ManifestItem(this.id, this.href, this.mediaType, {this.properties});

  final String id;
  final String href;
  final String mediaType;
  final String? properties;
}

class _TocEntry {
  const _TocEntry(this.title, this.href);

  final String title;
  final String href;
}
