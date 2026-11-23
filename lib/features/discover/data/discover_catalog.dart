import 'discover_models.dart';

/// One public library.
abstract class DiscoverCatalog {
  DiscoverSource get source;

  /// Browsable lists; the first is the default.
  List<DiscoverShelf> get shelves;

  Future<DiscoverPage> browse(DiscoverShelf shelf, {int page = 1});

  Future<DiscoverPage> search(String query, {int page = 1});

  /// Fills in what a listing leaves out: description, file size, and for
  /// Open Library whether there is a public file at all.
  Future<DiscoverBook> details(DiscoverBook book);
}

/// Plain text from a small HTML fragment.
String htmlToText(String html) {
  final withBreaks = html
      .replaceAll(RegExp(r'</p>\s*<p[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  return decodeHtmlEntities(withBreaks.replaceAll(RegExp(r'<[^>]+>'), ''))
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n\s*'), '\n\n')
      .trim();
}

String decodeHtmlEntities(String value) => value
    .replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
    )
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.parse(match[1]!)),
    )
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&rsquo;', '’')
    .replaceAll('&lsquo;', '‘')
    .replaceAll('&rdquo;', '”')
    .replaceAll('&ldquo;', '“')
    .replaceAll('&mdash;', '—')
    .replaceAll('&ndash;', '–')
    .replaceAll('&hellip;', '…')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
