import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/discover_models.dart';
import '../data/discover_providers.dart';
import '../data/discover_repository.dart';
import 'discover_book_screen.dart';
import 'discover_widgets.dart';

/// Browse and download free EPUBs from public libraries.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _search = TextEditingController();
  DiscoverSource source = DiscoverSource.standardEbooks;
  final _shelf = <DiscoverSource, DiscoverShelf>{};

  /// Pages loaded per source and shelf ("Load more").
  final _pages = <String, int>{};
  String query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  DiscoverShelf _shelfFor(DiscoverSource source) =>
      _shelf[source] ??
      ref.read(discoverRepositoryProvider).catalog(source).shelves.first;

  String _pagesKey(DiscoverSource source, DiscoverShelf shelf) =>
      '${source.name}/${shelf.id}';

  void _submit(String value) {
    FocusScope.of(context).unfocus();
    setState(() => query = value.trim());
  }

  void _clearSearch() {
    _search.clear();
    setState(() => query = '');
  }

  void _open(DiscoverBook book) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => DiscoverBookScreen(book: book)));

  Future<void> _refresh() async {
    ref.read(discoverHttpProvider).clearCache();
    if (query.isNotEmpty) {
      ref.invalidate(unifiedSearchProvider(query));
      await ref
          .read(unifiedSearchProvider(query).future)
          .catchError((_) => const UnifiedSearchResult(books: [], errors: {}));
      return;
    }
    final shelf = _shelfFor(source);
    final pages = _pages[_pagesKey(source, shelf)] ?? 1;
    for (var page = 1; page <= pages; page++) {
      ref.invalidate(
        shelfPageProvider((source: source, shelf: shelf, page: page)),
      );
    }
    await ref
        .read(shelfPageProvider((source: source, shelf: shelf, page: 1)).future)
        .catchError((_) => DiscoverPage.empty);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const BrutalAppBar(title: 'Discover'),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(child: _searchField()),
            if (query.isEmpty) ...[
              SliverToBoxAdapter(child: _sourceBar()),
              SliverToBoxAdapter(child: _shelfBar()),
              ..._browseSlivers(),
            ] else
              ..._searchSlivers(),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: ValueListenableBuilder(
        valueListenable: _search,
        builder: (context, value, _) => TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Search free books by title or author',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: value.text.isEmpty && query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _sourceBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          for (final value in DiscoverRepository.preference)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: BrutalChip(
                label: value.label,
                selected: source == value,
                onPressed: () => setState(() => source = value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shelfBar() {
    final catalog = ref.watch(discoverRepositoryProvider).catalog(source);
    final selected = _shelfFor(source);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          for (final shelf in catalog.shelves)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: shelf == selected
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                  backgroundColor: shelf == selected
                      ? BrutalColors.yellow.withValues(alpha: 0.35)
                      : null,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BrutalTokens.smallBorderRadius,
                  ),
                ),
                onPressed: () => setState(() => _shelf[source] = shelf),
                child: Text(
                  shelf.label,
                  style: TextStyle(
                    fontWeight: shelf == selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _browseSlivers() {
    final shelf = _shelfFor(source);
    final key = _pagesKey(source, shelf);
    final pageCount = _pages[key] ?? 1;
    final pages = [
      for (var page = 1; page <= pageCount; page++)
        ref.watch(
          shelfPageProvider((source: source, shelf: shelf, page: page)),
        ),
    ];
    final first = pages.first;
    if (first.isLoading && !first.hasValue) {
      return const [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          sliver: DiscoverSkeletonGrid(),
        ),
      ];
    }
    if (first.hasError && !first.hasValue) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DiscoverMessage(error: first.error!, onRetry: _refresh),
        ),
      ];
    }
    final books = <DiscoverBook>[
      for (final page in pages) ...?page.valueOrNull?.books,
    ];
    if (books.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.menu_book_outlined,
            title: 'Nothing here yet',
            message: 'Try another shelf or source.',
          ),
        ),
      ];
    }
    final last = pages.last;
    return [
      _grid(books, showSource: false),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Center(
            child: switch (last) {
              AsyncValue(isLoading: true) => const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              AsyncValue(:final error?) => Column(
                children: [
                  Text(
                    describeError(error),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: () => ref.invalidate(
                      shelfPageProvider((
                        source: source,
                        shelf: shelf,
                        page: pageCount,
                      )),
                    ),
                    child: const Text('Try again'),
                  ),
                ],
              ),
              AsyncValue(:final value?) when value.hasMore => BrutalPressable(
                backgroundColor: Theme.of(context).colorScheme.surface,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                onPressed: () => setState(() => _pages[key] = pageCount + 1),
                child: const Text('Load more'),
              ),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    ];
  }

  List<Widget> _searchSlivers() {
    final result = ref.watch(unifiedSearchProvider(query));
    final theme = Theme.of(context);
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text(
          'Results for “$query” in all libraries',
          style: theme.textTheme.titleMedium,
        ),
      ),
    );
    return switch (result) {
      AsyncValue(hasValue: false, isLoading: true) => [
        header,
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          sliver: DiscoverSkeletonGrid(),
        ),
      ],
      AsyncValue(hasValue: false, :final error?) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DiscoverMessage(error: error, onRetry: _refresh),
        ),
      ],
      AsyncValue(:final value?) => [
        if (value.books.isEmpty &&
            value.errors.length == DiscoverSource.values.length)
          SliverFillRemaining(
            hasScrollBody: false,
            child: DiscoverMessage(
              error: value.errors.values.first,
              onRetry: _refresh,
            ),
          )
        else if (value.books.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.search_off,
              title: 'No free books found',
              message: value.errors.isEmpty
                  ? 'Try a shorter title or just the author’s surname.'
                  : _partialFailure(value),
            ),
          )
        else ...[
          header,
          if (value.errors.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: BrutalCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _partialFailure(value),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          _grid(value.books, showSource: true),
        ],
      ],
      _ => const [],
    };
  }

  String _partialFailure(UnifiedSearchResult value) {
    final names = value.errors.keys.map((source) => source.label).join(' and ');
    return '$names did not answer, so some results may be missing.';
  }

  Widget _grid(List<DiscoverBook> books, {required bool showSource}) {
    final library = ref.watch(libraryIndexProvider);
    final downloads = ref.watch(downloadsProvider);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.builder(
        gridDelegate: discoverGridDelegate,
        itemCount: books.length,
        itemBuilder: (_, index) {
          final book = books[index];
          final owned = library.find(book);
          return DiscoverBookCard(
            book: book,
            showSource: showSource,
            inLibrary: owned != null && owned.filePath != null,
            download: downloads[book.key],
            onTap: () => _open(book),
          );
        },
      ),
    );
  }
}
