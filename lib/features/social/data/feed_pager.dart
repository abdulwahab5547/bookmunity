/// One page fetched from a single source, newest first.
class SourcePage<T> {
  const SourcePage(this.items, {required this.exhausted});

  final List<T> items;

  /// True when the source has nothing after these items.
  final bool exhausted;
}

/// A newest-first stream of items fetched page by page (e.g. one Firestore
/// query with a cursor).
abstract class PagedSource<T> {
  /// The next [count] items after the last ones returned.
  Future<SourcePage<T>> fetch(int count);
}

/// Merges several newest-first [PagedSource]s into one newest-first feed.
///
/// Needed because Firestore's `whereIn` takes at most 30 values: the Friends
/// feed runs one query per chunk of 30 authors. Each source keeps a buffer
/// of fetched-but-unshown items; a page takes the newest items across all
/// buffers, refilling a buffer only when it runs low, so nothing is skipped
/// or shown twice.
class MergedPager<T> {
  MergedPager(List<PagedSource<T>> sources, {required this.timeOf})
    : _sources = [for (final source in sources) _Buffered(source)];

  final List<_Buffered<T>> _sources;

  /// Sort key (newest first). Items without a time sort as "now".
  final DateTime? Function(T item) timeOf;

  bool get hasMore => _sources.any((s) => s.buffer.isNotEmpty || !s.exhausted);

  Future<List<T>> next(int count) async {
    final now = DateTime.now();
    final page = <T>[];
    while (page.length < count) {
      // Every source must show its next item before we can tell which is
      // newest; refill the empty ones (in parallel).
      await Future.wait([
        for (final source in _sources)
          if (!source.exhausted && source.buffer.isEmpty) source.fill(count),
      ]);
      _Buffered<T>? best;
      for (final source in _sources) {
        if (source.buffer.isEmpty) continue;
        if (best == null ||
            (timeOf(source.buffer.first) ?? now).isAfter(
              timeOf(best.buffer.first) ?? now,
            )) {
          best = source;
        }
      }
      if (best == null) break;
      page.add(best.buffer.removeAt(0));
    }
    return page;
  }
}

class _Buffered<T> {
  _Buffered(this.source);

  final PagedSource<T> source;
  final List<T> buffer = [];
  bool exhausted = false;

  Future<void> fill(int count) async {
    final page = await source.fetch(count);
    buffer.addAll(page.items);
    // An empty page also means the end, whatever the source claims.
    exhausted = page.exhausted || page.items.isEmpty;
  }
}

/// Splits [values] into lists of at most [size].
List<List<T>> chunked<T>(List<T> values, int size) => [
  for (var i = 0; i < values.length; i += size)
    values.sublist(i, i + size > values.length ? values.length : i + size),
];
