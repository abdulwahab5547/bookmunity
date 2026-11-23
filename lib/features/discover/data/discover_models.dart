enum DiscoverSource {
  gutenberg('Project Gutenberg', 'Gutenberg'),
  standardEbooks('Standard Ebooks', 'Standard Ebooks'),
  openLibrary('Open Library', 'Open Library');

  const DiscoverSource(this.label, this.shortLabel);

  final String label;
  final String shortLabel;
}

enum BookFormat {
  epub('EPUB'),

  /// Converted to EPUB on the device after downloading.
  pdf('PDF');

  const BookFormat(this.label);

  final String label;
}

/// One downloadable file. [urls] holds mirrors in order of preference; the
/// first one that answers is used and stored as the book's source URL.
class DownloadOption {
  const DownloadOption({
    required this.urls,
    required this.format,
    this.sizeBytes,
  });

  final List<String> urls;
  final BookFormat format;
  final int? sizeBytes;

  String get primaryUrl => urls.first;

  DownloadOption withSize(int? size) =>
      DownloadOption(urls: urls, format: format, sizeBytes: size ?? sizeBytes);
}

/// A book offered by a public library.
class DiscoverBook {
  const DiscoverBook({
    required this.source,
    required this.id,
    required this.title,
    this.authors = const [],
    this.coverUrl,
    this.summary,
    this.description,
    this.subjects = const [],
    this.languages = const [],
    this.download,
    this.year,
    this.popularity,
    this.pageUrl,
    this.archiveIds = const [],
    this.alsoFrom = const [],
  });

  final DiscoverSource source;

  /// Source-specific id: Gutenberg number, Standard Ebooks path, Open
  /// Library work key.
  final String id;
  final String title;

  /// Display names, "First Last".
  final List<String> authors;
  final String? coverUrl;

  /// One line, when the source has one.
  final String? summary;
  final String? description;
  final List<String> subjects;
  final List<String> languages;

  /// Known once the listing or details say where the file is. Open Library
  /// books only get one after their Internet Archive item is checked.
  final DownloadOption? download;
  final int? year;

  /// Downloads or reading-log count, for sorting merged results.
  final int? popularity;
  final String? pageUrl;

  /// Open Library: Internet Archive identifiers to check for a public file.
  final List<String> archiveIds;

  /// The same book from other sources, found while merging search results.
  final List<DiscoverBook> alsoFrom;

  String get key => '${source.name}:$id';

  String get authorLine =>
      authors.isEmpty ? 'Unknown author' : authors.join(', ');

  DiscoverBook copyWith({
    String? coverUrl,
    String? summary,
    String? description,
    List<String>? subjects,
    DownloadOption? download,
    List<DiscoverBook>? alsoFrom,
  }) => DiscoverBook(
    source: source,
    id: id,
    title: title,
    authors: authors,
    coverUrl: coverUrl ?? this.coverUrl,
    summary: summary ?? this.summary,
    description: description ?? this.description,
    subjects: subjects ?? this.subjects,
    languages: languages,
    download: download ?? this.download,
    year: year,
    popularity: popularity,
    pageUrl: pageUrl,
    archiveIds: archiveIds,
    alsoFrom: alsoFrom ?? this.alsoFrom,
  );
}

/// A page of results.
class DiscoverPage {
  const DiscoverPage({required this.books, this.hasMore = false, this.total});

  final List<DiscoverBook> books;
  final bool hasMore;
  final int? total;

  static const empty = DiscoverPage(books: []);
}

/// A browsable list within a source: popular, new, or a subject.
class DiscoverShelf {
  const DiscoverShelf(this.id, this.label);

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DiscoverShelf && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// The device could not reach the network at all.
class DiscoverOfflineException implements Exception {
  const DiscoverOfflineException();

  @override
  String toString() => 'You appear to be offline.';
}

/// A source answered with an error or something unexpected.
class DiscoverSourceException implements Exception {
  const DiscoverSourceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Catalogue names to display names: "Austen, Jane" → "Jane Austen",
/// "Wells, H. G. (Herbert George), 1866-1946" → "H. G. Wells".
String displayAuthorName(String name) {
  final parts = name
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .split(',')
      .map((part) => part.trim())
      // Life dates and empty fragments.
      .where(
        (part) => part.isNotEmpty && !RegExp(r'^[\d\s?\-–]+$').hasMatch(part),
      )
      .toList();
  if (parts.length == 2) return '${parts[1]} ${parts[0]}';
  return parts.join(', ');
}

/// Same slug as `EpubMetadataExtractor`, so a listing can be matched with a
/// library book's `bookKey`.
String bookKeySlug(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'-+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

/// Normalised title for merging duplicates across sources: lower case,
/// no subtitle, no leading article, letters and digits only.
String dedupeTitle(String title) {
  var value = title.toLowerCase();
  value = value.split(RegExp(r'[:;(]|\s—\s|\s-\s')).first;
  value = value.replaceAll(RegExp(r'^(the|a|an)\s+'), '');
  return value.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// Surname used for merging duplicates.
String dedupeAuthor(List<String> authors) {
  if (authors.isEmpty) return '';
  final words = authors.first
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.length > 1)
      .toList();
  return words.isEmpty ? '' : words.last;
}
