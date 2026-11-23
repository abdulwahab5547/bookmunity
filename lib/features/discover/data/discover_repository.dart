import 'dart:async';

import 'discover_catalog.dart';
import 'discover_models.dart';

class UnifiedSearchResult {
  const UnifiedSearchResult({required this.books, required this.errors});

  final List<DiscoverBook> books;

  /// Sources that failed, with their error. The others still answered.
  final Map<DiscoverSource, Object> errors;

  bool get offline =>
      errors.isNotEmpty &&
      errors.values.every((error) => error is DiscoverOfflineException);
}

/// All catalogues together: per-source browsing and one search across them.
class DiscoverRepository {
  DiscoverRepository(this.catalogs);

  final List<DiscoverCatalog> catalogs;

  /// When the same book comes from several sources, the first source in
  /// this list is shown and the others are kept as alternatives.
  static const preference = [
    DiscoverSource.standardEbooks,
    DiscoverSource.gutenberg,
    DiscoverSource.openLibrary,
  ];

  DiscoverCatalog catalog(DiscoverSource source) =>
      catalogs.firstWhere((catalog) => catalog.source == source);

  Future<UnifiedSearchResult> searchAll(String query) async {
    final results = <DiscoverSource, List<DiscoverBook>>{};
    final errors = <DiscoverSource, Object>{};
    await Future.wait([
      for (final catalog in catalogs)
        catalog
            .search(query)
            .then((page) => results[catalog.source] = page.books)
            .catchError((Object error) {
              errors[catalog.source] = error;
              return const <DiscoverBook>[];
            }),
    ]);
    return UnifiedSearchResult(books: merge(results), errors: errors);
  }

  /// Interleaves results by rank and folds obvious duplicates (same title
  /// without subtitle, same author surname) into one entry.
  static List<DiscoverBook> merge(
    Map<DiscoverSource, List<DiscoverBook>> results,
  ) {
    final merged = <DiscoverBook>[];
    final byKey = <String, int>{};
    final longest = results.values.fold(
      0,
      (length, list) => list.length > length ? list.length : length,
    );
    for (var rank = 0; rank < longest; rank++) {
      for (final source in preference) {
        final list = results[source];
        if (list == null || rank >= list.length) continue;
        final book = list[rank];
        final key = '${dedupeTitle(book.title)}|${dedupeAuthor(book.authors)}';
        final existing = byKey[key];
        if (existing == null || dedupeTitle(book.title).isEmpty) {
          byKey[key] = merged.length;
          merged.add(book);
          continue;
        }
        final current = merged[existing];
        if (current.source == book.source) {
          // Two editions in the same catalogue: keep both.
          merged.add(book);
          continue;
        }
        if (current.alsoFrom.any((other) => other.source == book.source)) {
          continue;
        }
        if (preference.indexOf(book.source) <
            preference.indexOf(current.source)) {
          merged[existing] = book.copyWith(
            alsoFrom: [
              current.copyWith(alsoFrom: const []),
              ...current.alsoFrom,
            ],
          );
        } else {
          merged[existing] = current.copyWith(
            alsoFrom: [...current.alsoFrom, book],
          );
        }
      }
    }
    return merged;
  }
}
