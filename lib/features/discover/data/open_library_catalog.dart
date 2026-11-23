import 'discover_catalog.dart';
import 'discover_http.dart';
import 'discover_models.dart';

/// Open Library (https://openlibrary.org) search, limited to works with a
/// public-domain scan (`ebook_access:public`). Borrow-only books are never
/// offered.
///
/// Open Library has no files itself: the scans live on the Internet
/// Archive, listed as `ia` identifiers. [details] checks those items through
/// archive.org's metadata API and offers the first unrestricted EPUB (or a
/// text PDF, converted on the device).
class OpenLibraryCatalog implements DiscoverCatalog {
  OpenLibraryCatalog(this.http);

  final DiscoverHttp http;

  static const base = 'https://openlibrary.org';
  static const pageSize = 24;

  /// PDFs larger than this are too heavy to download and convert on a
  /// phone (scans of big books reach hundreds of megabytes).
  static const maxPdfBytes = 120 * 1024 * 1024;

  static const _fields =
      'key,title,author_name,first_publish_year,cover_i,ia,ebook_access,'
      'public_scan_b,lending_identifier_s,subject,language,readinglog_count';

  static const popular = DiscoverShelf('popular', 'Most read');

  static const _subjects = {
    'Fiction': 'fiction',
    'Science fiction': 'science_fiction',
    'Mystery': 'mystery',
    'Romance': 'romance',
    'Fantasy': 'fantasy',
    'Horror': 'horror',
    'Poetry': 'poetry',
    'Philosophy': 'philosophy',
    'History': 'history',
    'Children': 'juvenile_fiction',
  };

  @override
  DiscoverSource get source => DiscoverSource.openLibrary;

  @override
  List<DiscoverShelf> get shelves => [
    popular,
    for (final entry in _subjects.entries)
      DiscoverShelf('subject:${entry.value}', entry.key),
  ];

  @override
  Future<DiscoverPage> browse(DiscoverShelf shelf, {int page = 1}) {
    final query = shelf.id.startsWith('subject:')
        ? 'subject_key:${shelf.id.substring('subject:'.length)} AND '
              'ebook_access:public'
        : 'ebook_access:public';
    return _search(query, page, sort: 'readinglog');
  }

  @override
  Future<DiscoverPage> search(String query, {int page = 1}) {
    final words = sanitizeQuery(query);
    if (words.isEmpty) return Future.value(DiscoverPage.empty);
    return _search('($words) AND ebook_access:public', page);
  }

  /// Keeps words only, so user input cannot change the Solr query.
  static String sanitizeQuery(String query) => query
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\b(AND|OR|NOT)\b'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<DiscoverPage> _search(String q, int page, {String? sort}) async {
    final url = Uri.parse('$base/search.json').replace(
      queryParameters: {
        'q': q,
        'fields': _fields,
        'limit': '$pageSize',
        'page': '$page',
        'sort': ?sort,
      },
    );
    final json = await http.getJson(url, timeout: const Duration(seconds: 30));
    return parseSearch(json as Map<String, dynamic>, page: page);
  }

  static DiscoverPage parseSearch(Map<String, dynamic> json, {int page = 1}) {
    final books = <DiscoverBook>[];
    for (final doc in (json['docs'] as List? ?? const []).cast<Map>()) {
      if (doc['ebook_access'] != 'public') continue;
      final key = doc['key'] as String?;
      final title = doc['title'] as String?;
      if (key == null || title == null) continue;
      final lending = doc['lending_identifier_s'] as String?;
      final archiveIds = <String>{
        ?lending,
        ...(doc['ia'] as List? ?? const []).cast<String>(),
      }.toList();
      if (archiveIds.isEmpty) continue;
      final cover = doc['cover_i'];
      books.add(
        DiscoverBook(
          source: DiscoverSource.openLibrary,
          id: key,
          title: title.trim(),
          authors: (doc['author_name'] as List? ?? const [])
              .cast<String>()
              .take(3)
              .toList(),
          coverUrl: cover is int
              ? 'https://covers.openlibrary.org/b/id/$cover-M.jpg'
              : null,
          subjects: (doc['subject'] as List? ?? const [])
              .cast<String>()
              .take(8)
              .toList(),
          languages: (doc['language'] as List? ?? const [])
              .cast<String>()
              .take(4)
              .toList(),
          year: doc['first_publish_year'] as int?,
          popularity: doc['readinglog_count'] as int?,
          pageUrl: '$base$key',
          archiveIds: archiveIds,
        ),
      );
    }
    final total = json['numFound'] as int?;
    return DiscoverPage(
      books: books,
      total: total,
      hasMore: total != null && page * pageSize < total,
    );
  }

  @override
  Future<DiscoverBook> details(DiscoverBook book) async {
    var result = book;
    if (book.description == null) {
      try {
        final work = await http.getJson(Uri.parse('$base${book.id}.json'));
        final description = (work as Map)['description'];
        final text = description is Map
            ? description['value'] as String?
            : description as String?;
        if (text != null && text.trim().isNotEmpty) {
          result = result.copyWith(description: text.trim());
        }
      } on Exception {
        // The description is optional.
      }
    }
    if (result.download == null) {
      final download = await findPublicFile(book.archiveIds);
      if (download != null) result = result.copyWith(download: download);
    }
    return result;
  }

  /// The first Internet Archive item among [ids] that is not restricted and
  /// has an EPUB or a text PDF.
  Future<DownloadOption?> findPublicFile(List<String> ids) async {
    for (final id in ids.take(4)) {
      try {
        final json = await http.getJson(
          Uri.parse('https://archive.org/metadata/${Uri.encodeComponent(id)}'),
          timeout: const Duration(seconds: 20),
        );
        final option = pickArchiveFile(id, json as Map<String, dynamic>);
        if (option != null) return option;
      } on DiscoverOfflineException {
        rethrow;
      } on Exception {
        continue;
      }
    }
    return null;
  }

  /// Chooses a public file from an archive.org metadata response, or null
  /// when the item is lending-only.
  static DownloadOption? pickArchiveFile(String id, Map<String, dynamic> json) {
    final metadata = (json['metadata'] as Map?) ?? const {};
    final restricted = metadata['access-restricted-item'];
    if (restricted == true || restricted == 'true') return null;
    final mediatype = metadata['mediatype'];
    if (mediatype != null && mediatype != 'texts') return null;
    final files = (json['files'] as List? ?? const []).cast<Map>();
    bool open(Map file) => file['private'] != true && file['private'] != 'true';
    int? sizeOf(Map file) => int.tryParse('${file['size'] ?? ''}');
    String url(Map file) =>
        'https://archive.org/download/${Uri.encodeComponent(id)}/'
        '${Uri.encodeComponent(file['name'] as String)}';

    final epub = files.where((file) {
      final name = (file['name'] as String? ?? '').toLowerCase();
      return open(file) &&
          name.endsWith('.epub') &&
          !name.endsWith('_lcp.epub') &&
          file['format'] == 'EPUB';
    }).firstOrNull;
    if (epub != null) {
      return DownloadOption(
        urls: [url(epub)],
        format: BookFormat.epub,
        sizeBytes: sizeOf(epub),
      );
    }
    final pdf = files.where((file) {
      final name = (file['name'] as String? ?? '').toLowerCase();
      final size = sizeOf(file);
      return open(file) &&
          name.endsWith('.pdf') &&
          !name.endsWith('_encrypted.pdf') &&
          file['format'] == 'Text PDF' &&
          (size == null || size <= maxPdfBytes);
    }).firstOrNull;
    if (pdf != null) {
      return DownloadOption(
        urls: [url(pdf)],
        format: BookFormat.pdf,
        sizeBytes: sizeOf(pdf),
      );
    }
    return null;
  }
}
