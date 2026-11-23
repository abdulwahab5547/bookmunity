import 'package:xml/xml.dart';

import 'discover_catalog.dart';
import 'discover_http.dart';
import 'discover_models.dart';

/// Standard Ebooks (https://standardebooks.org).
///
/// Their OPDS and full Atom catalogue need a Patrons Circle login, but these
/// are public: the "new releases" Atom feed, Atom search results
/// (`/feeds/atom/all?query=…`), and the HTML catalogue pages (popular and
/// per subject). Downloads are public too; a plain `.epub` link answers
/// with a thank-you page, so links carry `?source=download`, which is where
/// that page redirects.
class StandardEbooksCatalog implements DiscoverCatalog {
  StandardEbooksCatalog(this.http);

  final DiscoverHttp http;

  static const base = 'https://standardebooks.org';
  static const pageSize = 24;

  static const popular = DiscoverShelf('popular', 'Popular');
  static const newest = DiscoverShelf('new', 'New releases');

  static const _subjects = {
    'Fiction': 'fiction',
    'Adventure': 'adventure',
    'Fantasy': 'fantasy',
    'Science fiction': 'science-fiction',
    'Mystery': 'mystery',
    'Horror': 'horror',
    'Short stories': 'shorts',
    'Poetry': 'poetry',
    'Drama': 'drama',
    'Philosophy': 'philosophy',
    'Children': 'childrens',
    'Travel': 'travel',
  };

  @override
  DiscoverSource get source => DiscoverSource.standardEbooks;

  @override
  List<DiscoverShelf> get shelves => [
    popular,
    newest,
    for (final entry in _subjects.entries)
      DiscoverShelf('subject:${entry.value}', entry.key),
  ];

  @override
  Future<DiscoverPage> browse(DiscoverShelf shelf, {int page = 1}) async {
    if (shelf == newest) {
      if (page > 1) return DiscoverPage.empty;
      final xml = await http.getText(
        Uri.parse('$base/feeds/atom/new-releases'),
        accept: 'application/atom+xml',
      );
      return DiscoverPage(books: parseAtom(xml).books);
    }
    final path = shelf.id.startsWith('subject:')
        ? '/subjects/${shelf.id.substring('subject:'.length)}'
        : '/ebooks';
    final url = Uri.parse('$base$path').replace(
      queryParameters: {
        'sort': 'popularity',
        'view': 'list',
        'per-page': '$pageSize',
        if (page > 1) 'page': '$page',
      },
    );
    return parseCatalogue(await http.getText(url), page: page);
  }

  @override
  Future<DiscoverPage> search(String query, {int page = 1}) async {
    final url = Uri.parse('$base/feeds/atom/all').replace(
      queryParameters: {
        'query': query.trim(),
        'per-page': '$pageSize',
        'page': '$page',
      },
    );
    final xml = await http.getText(url, accept: 'application/atom+xml');
    return parseAtom(xml, page: page);
  }

  @override
  Future<DiscoverBook> details(DiscoverBook book) async {
    var result = book;
    if (book.description == null) {
      // Catalogue pages carry no blurb; the Atom search entry does.
      try {
        final found = await search(book.title);
        final match = found.books.where((entry) => entry.id == book.id);
        if (match.isNotEmpty) {
          final full = match.first;
          result = book.copyWith(
            summary: full.summary,
            description: full.description,
            subjects: full.subjects.isEmpty ? null : full.subjects,
            download: full.download,
            coverUrl: book.coverUrl ?? full.coverUrl,
          );
        }
      } on Exception {
        // The listing is still usable without the blurb.
      }
    }
    final download = result.download;
    if (download != null && download.sizeBytes == null) {
      final size = await http.contentLength(Uri.parse(download.primaryUrl));
      result = result.copyWith(download: download.withSize(size));
    }
    return result;
  }

  /// `/ebooks/bram-stoker/dracula` →
  /// `https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub?source=download`
  static String downloadUrlFor(String path) {
    final segments = Uri.parse(path).pathSegments.skip(1).toList();
    return '$base/ebooks/${segments.join('/')}/downloads/'
        '${segments.join('_')}.epub?source=download';
  }

  static String _path(String idOrUrl) =>
      Uri.parse(idOrUrl).path.replaceFirst(RegExp(r'/$'), '');

  static DiscoverPage parseAtom(String xml, {int page = 1}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException {
      throw const DiscoverSourceException(
        'Standard Ebooks sent an unexpected answer.',
      );
    }
    final books = <DiscoverBook>[];
    for (final entry in document.findAllElements('entry')) {
      final id = entry.getElement('id')?.innerText.trim();
      final title = entry.getElement('title')?.innerText.trim();
      if (id == null || title == null) continue;
      final path = _path(id);
      String? epub;
      int? size;
      for (final link in entry.findElements('link')) {
        if (link.getAttribute('rel') != 'enclosure') continue;
        if (link.getAttribute('type') != 'application/epub+zip') continue;
        final href = link.getAttribute('href') ?? '';
        // The first EPUB is the "recommended compatible" one.
        epub = href.replaceFirst(RegExp(r'\?source=\w+'), '?source=download');
        size = int.tryParse(link.getAttribute('length') ?? '');
        break;
      }
      final thumbnail = entry
          .findElements('thumbnail', namespace: 'http://search.yahoo.com/mrss/')
          .firstOrNull
          ?.getAttribute('url');
      final subjects = <String>[
        for (final category in entry.findElements('category'))
          if (category.getAttribute('scheme')?.contains('standardebooks') ??
              false)
            category.getAttribute('term') ?? '',
        for (final category in entry.findElements('category'))
          if (!(category.getAttribute('scheme')?.contains('standardebooks') ??
              false))
            (category.getAttribute('term') ?? '').split('--').first.trim(),
      ].where((term) => term.isNotEmpty).toSet().take(10).toList();
      final content = entry.getElement('content')?.innerText;
      books.add(
        DiscoverBook(
          source: DiscoverSource.standardEbooks,
          id: path,
          title: title,
          authors: [
            for (final author in entry.findElements('author'))
              author.getElement('name')?.innerText.trim() ?? '',
          ].where((name) => name.isNotEmpty).toList(),
          coverUrl: thumbnail,
          summary: entry.getElement('summary')?.innerText.trim(),
          description: content == null ? null : htmlToText(content),
          subjects: subjects,
          languages: const ['en'],
          pageUrl: '$base$path',
          download: DownloadOption(
            urls: [epub ?? downloadUrlFor(path)],
            format: BookFormat.epub,
            sizeBytes: size,
          ),
        ),
      );
    }
    final total = int.tryParse(
      document.descendants
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'totalResults')
              .firstOrNull
              ?.innerText ??
          '',
    );
    return DiscoverPage(
      books: books,
      total: total,
      hasMore: total != null && page * pageSize < total,
    );
  }

  static final _item = RegExp(
    r'<li[^>]*typeof="schema:Book"[^>]*about="([^"]+)"[^>]*>(.*?)</li>\s*(?=<li[^>]*typeof="schema:Book"|</ol>)',
    dotAll: true,
  );

  /// Parses a catalogue page (`/ebooks`, `/subjects/…`). The markup carries
  /// schema.org RDFa attributes, which are what this relies on.
  static DiscoverPage parseCatalogue(String html, {int page = 1}) {
    final books = <DiscoverBook>[];
    for (final match in _item.allMatches(html)) {
      final path = _path(match[1]!);
      final body = match[2]!;
      final title = RegExp(
        r'property="schema:name"[^>]*>([^<]+)<',
      ).firstMatch(body)?[1];
      if (title == null) continue;
      final authorBlock = RegExp(
        r'<p class="author"[^>]*>(.*?)</p>',
        dotAll: true,
      ).allMatches(body).map((m) => htmlToText(m[1]!)).toList();
      final image = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(body)?[1];
      final tags = RegExp(
        r'<a href="/subjects/[^"]+">([^<]+)</a>',
      ).allMatches(body).map((m) => decodeHtmlEntities(m[1]!.trim()));
      books.add(
        DiscoverBook(
          source: DiscoverSource.standardEbooks,
          id: path,
          title: decodeHtmlEntities(title.trim()),
          authors: authorBlock.where((name) => name.isNotEmpty).toList(),
          coverUrl: image == null
              ? null
              : Uri.parse(base).resolve(image).toString(),
          subjects: tags.toList(),
          languages: const ['en'],
          pageUrl: '$base$path',
          download: DownloadOption(
            urls: [downloadUrlFor(path)],
            format: BookFormat.epub,
          ),
        ),
      );
    }
    final hasMore =
        html.contains('page=${page + 1}&amp;') ||
        html.contains('page=${page + 1}"');
    return DiscoverPage(books: books, hasMore: hasMore);
  }
}
