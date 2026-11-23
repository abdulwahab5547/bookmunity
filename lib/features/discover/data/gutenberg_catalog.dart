import 'discover_catalog.dart';
import 'discover_http.dart';
import 'discover_models.dart';

/// Project Gutenberg through Gutendex (https://gutendex.com), a JSON API
/// over the official catalogue. Only public-domain books with an EPUB are
/// listed.
class GutenbergCatalog implements DiscoverCatalog {
  GutenbergCatalog(this.http, {this.baseUrl = 'https://gutendex.com'});

  final DiscoverHttp http;
  final String baseUrl;

  /// Serves Gutenberg's files when www.gutenberg.org is down.
  static const mirror = 'https://gutenberg.pglaf.org';

  static const popular = DiscoverShelf('popular', 'Popular');
  static const newest = DiscoverShelf('newest', 'Recently added');

  static const _topics = {
    'Adventure': 'adventure',
    'Science fiction': 'science fiction',
    'Mystery': 'detective',
    'Romance': 'love stories',
    'Horror': 'horror',
    'Children': 'children',
    'Poetry': 'poetry',
    'Philosophy': 'philosophy',
    'History': 'history',
    'Humour': 'humor',
  };

  @override
  DiscoverSource get source => DiscoverSource.gutenberg;

  @override
  List<DiscoverShelf> get shelves => [
    popular,
    newest,
    for (final entry in _topics.entries)
      DiscoverShelf('topic:${entry.value}', entry.key),
  ];

  @override
  Future<DiscoverPage> browse(DiscoverShelf shelf, {int page = 1}) {
    final params = <String, String>{
      'sort': shelf == newest ? 'descending' : 'popular',
    };
    if (shelf.id.startsWith('topic:')) {
      params['topic'] = shelf.id.substring('topic:'.length);
    }
    return _list(params, page);
  }

  @override
  Future<DiscoverPage> search(String query, {int page = 1}) =>
      _list({'search': query.trim(), 'sort': 'popular'}, page);

  Future<DiscoverPage> _list(Map<String, String> params, int page) async {
    final url = Uri.parse('$baseUrl/books/').replace(
      queryParameters: {
        ...params,
        'copyright': 'false',
        'mime_type': 'application/epub',
        if (page > 1) 'page': '$page',
      },
    );
    final json = await http.getJson(url, timeout: const Duration(seconds: 30));
    return parsePage(json as Map<String, dynamic>);
  }

  static DiscoverPage parsePage(Map<String, dynamic> json) {
    final results = (json['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(parseBook)
        .nonNulls
        .toList();
    return DiscoverPage(
      books: results,
      hasMore: json['next'] != null,
      total: json['count'] as int?,
    );
  }

  static DiscoverBook? parseBook(Map<String, dynamic> json) {
    final id = json['id'];
    final formats = (json['formats'] as Map?)?.cast<String, dynamic>() ?? {};
    final epub = formats.entries
        .where((entry) => entry.key.startsWith('application/epub+zip'))
        .map((entry) => entry.value as String)
        .firstOrNull;
    if (id is! int || epub == null || json['copyright'] == true) return null;
    final summaries = (json['summaries'] as List? ?? const []).cast<String>();
    final shelves = (json['bookshelves'] as List? ?? const [])
        .cast<String>()
        .map((shelf) => shelf.replaceFirst('Category: ', ''));
    final subjects = <String>{
      ...(json['subjects'] as List? ?? const []).cast<String>().map(
        (subject) => subject.split(' -- ').first,
      ),
      ...shelves,
    };
    return DiscoverBook(
      source: DiscoverSource.gutenberg,
      id: '$id',
      title: (json['title'] as String? ?? 'Untitled').trim(),
      authors: [
        for (final author in (json['authors'] as List? ?? const []).cast<Map>())
          displayAuthorName(author['name'] as String? ?? ''),
      ].where((name) => name.isNotEmpty).toList(),
      coverUrl: formats['image/jpeg'] as String?,
      description: summaries.isEmpty
          ? null
          : summaries.first.replaceFirst(
              RegExp(r'\s*\(This is an automatically generated summary\.\)$'),
              '',
            ),
      subjects: subjects.take(10).toList(),
      languages: (json['languages'] as List? ?? const []).cast<String>(),
      popularity: json['download_count'] as int?,
      pageUrl: 'https://www.gutenberg.org/ebooks/$id',
      download: DownloadOption(
        urls: [epub, '$mirror/cache/epub/$id/pg$id-images-3.epub'],
        format: BookFormat.epub,
      ),
    );
  }

  @override
  Future<DiscoverBook> details(DiscoverBook book) async {
    final download = book.download;
    if (download == null || download.sizeBytes != null) return book;
    for (final url in download.urls) {
      final size = await http.contentLength(Uri.parse(url));
      if (size != null && size > 0) {
        return book.copyWith(download: download.withSize(size));
      }
    }
    return book;
  }
}
