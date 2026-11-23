import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/import/epub_import_service.dart';
import '../../../providers/app_providers.dart';
import 'book_downloader.dart';
import 'discover_catalog.dart';
import 'discover_http.dart';
import 'discover_models.dart';
import 'discover_repository.dart';
import 'gutenberg_catalog.dart';
import 'open_library_catalog.dart';
import 'standard_ebooks_catalog.dart';

final discoverHttpProvider = Provider<DiscoverHttp>((ref) => DiscoverHttp());

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  final http = ref.watch(discoverHttpProvider);
  return DiscoverRepository([
    StandardEbooksCatalog(http),
    GutenbergCatalog(http),
    OpenLibraryCatalog(http),
  ]);
});

final bookDownloaderProvider = Provider<BookDownloader>(
  (ref) => BookDownloader(),
);

typedef ShelfRequest = ({DiscoverSource source, DiscoverShelf shelf, int page});

/// One page of a shelf. Kept for the session (the HTTP layer caches too),
/// so switching tabs and shelves is instant.
final shelfPageProvider = FutureProvider.family<DiscoverPage, ShelfRequest>((
  ref,
  request,
) {
  final catalog = ref.watch(discoverRepositoryProvider).catalog(request.source);
  return catalog.browse(request.shelf, page: request.page);
});

final unifiedSearchProvider =
    FutureProvider.family<UnifiedSearchResult, String>((ref, query) {
      return ref.watch(discoverRepositoryProvider).searchAll(query);
    });

final bookDetailsProvider = FutureProvider.autoDispose
    .family<DiscoverBook, DiscoverBook>((ref, book) {
      final catalog = ref
          .watch(discoverRepositoryProvider)
          .catalog(book.source);
      ref.keepAlive();
      return catalog.details(book);
    });

// ---------------------------------------------------------------------------
// What is already in the library

class LibraryIndex {
  LibraryIndex(List<Book> books) {
    for (final book in books) {
      final url = book.sourceUrl;
      if (url != null) _byUrl[normalizeSourceUrl(url)] = book;
      if (book.bookKey.isNotEmpty) _byKey[book.bookKey] = book;
    }
  }

  final _byUrl = <String, Book>{};
  final _byKey = <String, Book>{};

  /// The library row for [book]: same download URL (any mirror, any
  /// source it was merged with), or the same title and author key.
  Book? find(DiscoverBook book) {
    for (final candidate in [book, ...book.alsoFrom]) {
      for (final url in candidate.download?.urls ?? const <String>[]) {
        final match = _byUrl[normalizeSourceUrl(url)];
        if (match != null) return match;
      }
      for (final author
          in candidate.authors.isEmpty ? [''] : candidate.authors) {
        final key =
            '${bookKeySlug(candidate.title)}|'
            '${bookKeySlug(author.isEmpty ? 'UNKNOWN AUTHOR' : author)}';
        final match = _byKey[key];
        if (match != null) return match;
      }
    }
    return null;
  }

  /// Host and path, lower case, without query or fragment, so
  /// `…/dracula.epub?source=feed` and `?source=download` match.
  static String normalizeSourceUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim().toLowerCase();
    return '${uri.host.toLowerCase()}${uri.path.toLowerCase()}';
  }
}

final libraryIndexProvider = Provider<LibraryIndex>((ref) {
  final books = ref.watch(booksProvider).valueOrNull ?? const <Book>[];
  return LibraryIndex(books);
});

// ---------------------------------------------------------------------------
// Downloads

enum DownloadPhase { downloading, converting, importing, done, failed }

class DownloadState {
  const DownloadState({
    required this.phase,
    this.received = 0,
    this.total,
    this.conversion,
    this.stage,
    this.error,
    this.bookId,
    this.scanned = false,
    this.duplicate = false,
  });

  final DownloadPhase phase;
  final int received;
  final int? total;

  /// 0–1 while converting a PDF.
  final double? conversion;
  final String? stage;
  final String? error;
  final int? bookId;
  final bool scanned;
  final bool duplicate;

  bool get active =>
      phase == DownloadPhase.downloading ||
      phase == DownloadPhase.converting ||
      phase == DownloadPhase.importing;

  /// Overall progress, or null when unknown.
  double? get fraction => switch (phase) {
    DownloadPhase.downloading =>
      total == null || total == 0 ? null : received / total!,
    DownloadPhase.converting => conversion,
    DownloadPhase.importing => null,
    DownloadPhase.done => 1,
    DownloadPhase.failed => null,
  };
}

/// Downloads keyed by [DiscoverBook.key]. Lives for the app session, so a
/// download keeps going while the user browses elsewhere.
class DownloadsController extends StateNotifier<Map<String, DownloadState>> {
  DownloadsController(this.ref) : super(const {});

  final Ref ref;
  final _tokens = <String, (DownloadCancelToken, PdfConversionCancelToken)>{};

  DownloadState? stateFor(DiscoverBook book) => state[book.key];

  void _set(String key, DownloadState value) => state = {...state, key: value};

  void clear(DiscoverBook book) {
    state = {...state}..remove(book.key);
  }

  void cancel(DiscoverBook book) {
    final tokens = _tokens[book.key];
    tokens?.$1.cancel();
    tokens?.$2.cancel();
  }

  Future<void> start(DiscoverBook book) async {
    final key = book.key;
    if (state[key]?.active ?? false) return;
    final option = book.download;
    if (option == null) return;
    final tokens = (DownloadCancelToken(), PdfConversionCancelToken());
    _tokens[key] = tokens;
    _set(
      key,
      DownloadState(phase: DownloadPhase.downloading, total: option.sizeBytes),
    );
    try {
      final file = await ref
          .read(bookDownloaderProvider)
          .download(
            option,
            cancelToken: tokens.$1,
            onProgress: (received, total) {
              if (!mounted) return;
              _set(
                key,
                DownloadState(
                  phase: DownloadPhase.downloading,
                  received: received,
                  total: total ?? option.sizeBytes,
                ),
              );
            },
          );
      final service = await ref.read(importServiceProvider.future);
      _set(
        key,
        DownloadState(
          phase: file.format == BookFormat.pdf
              ? DownloadPhase.converting
              : DownloadPhase.importing,
          conversion: 0,
          stage: file.format == BookFormat.pdf ? 'Converting PDF' : null,
        ),
      );
      final result = await service.importBytes(
        file.bytes,
        filename: _filename(book, file.format),
        sourceUrl: file.url,
        cancelToken: tokens.$2,
        onProgress: (fraction, stage) {
          if (!mounted) return;
          _set(
            key,
            DownloadState(
              phase: DownloadPhase.converting,
              conversion: fraction,
              stage: stage,
            ),
          );
        },
      );
      _set(
        key,
        DownloadState(
          phase: DownloadPhase.done,
          bookId: result.bookId,
          scanned: result.scannedPdf,
          duplicate: result.duplicate,
        ),
      );
    } on DownloadCancelled {
      clear(book);
    } on PdfConversionCancelled {
      clear(book);
    } catch (error) {
      _set(
        key,
        DownloadState(phase: DownloadPhase.failed, error: describeError(error)),
      );
    } finally {
      _tokens.remove(key);
    }
  }

  static String _filename(DiscoverBook book, BookFormat format) {
    final base = book.title
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return '${base.isEmpty ? 'book' : base}.${format == BookFormat.pdf ? 'pdf' : 'epub'}';
  }
}

String describeError(Object error) => switch (error) {
  DiscoverOfflineException() => 'You are offline. Connect and try again.',
  DiscoverSourceException(:final message) => message,
  FormatException(:final message) => _sentenceCase(message),
  _ => 'Something went wrong: $error',
};

String _sentenceCase(String message) {
  if (message.isEmpty || message != message.toUpperCase()) return message;
  final lower = message.toLowerCase();
  return lower[0].toUpperCase() + lower.substring(1);
}

final downloadsProvider =
    StateNotifierProvider<DownloadsController, Map<String, DownloadState>>(
      (ref) => DownloadsController(ref),
    );

/// Catalogues, exposed for widgets that list sources.
final discoverCatalogsProvider = Provider<List<DiscoverCatalog>>(
  (ref) => ref.watch(discoverRepositoryProvider).catalogs,
);
