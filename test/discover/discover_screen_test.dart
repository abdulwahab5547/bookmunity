import 'dart:convert';
import 'dart:io';

import 'package:bookmunity/core/db/app_database.dart';
import 'package:bookmunity/design/brutal_theme.dart';
import 'package:bookmunity/features/discover/data/discover_http.dart';
import 'package:bookmunity/features/discover/data/discover_models.dart';
import 'package:bookmunity/features/discover/data/discover_providers.dart';
import 'package:bookmunity/features/discover/data/discover_repository.dart';
import 'package:bookmunity/features/discover/data/gutenberg_catalog.dart';
import 'package:bookmunity/features/discover/data/open_library_catalog.dart';
import 'package:bookmunity/features/discover/data/standard_ebooks_catalog.dart';
import 'package:bookmunity/features/discover/presentation/discover_book_screen.dart';
import 'package:bookmunity/features/discover/presentation/discover_screen.dart';
import 'package:bookmunity/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _fixture(String name) =>
    File('test/fixtures/discover/$name').readAsStringSync();

http.Response _ok(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'text/plain; charset=utf-8'},
);

/// Serves the saved real responses; anything else fails like a dead host.
MockClient _fixtureClient({bool offline = false}) =>
    MockClient((request) async {
      if (offline) {
        throw http.ClientException('Failed host lookup: ${request.url.host}');
      }
      final url = request.url;
      if (url.host == 'standardebooks.org') {
        if (url.path == '/ebooks') {
          return _ok(_fixture('standard_ebooks_popular.html'));
        }
        if (url.path.startsWith('/subjects/')) {
          return _ok(_fixture('standard_ebooks_subject_horror.html'));
        }
        if (url.path == '/feeds/atom/all') {
          return _ok(_fixture('standard_ebooks_search_dracula.xml'));
        }
        if (url.path == '/feeds/atom/new-releases') {
          return _ok(_fixture('standard_ebooks_new_releases.xml'));
        }
      }
      if (url.host == 'gutendex.com') {
        return _ok(
          url.queryParameters.containsKey('search')
              ? _fixture('gutendex_search_dracula.json')
              : _fixture('gutendex_popular.json'),
        );
      }
      if (url.host == 'openlibrary.org' && url.path == '/search.json') {
        return _ok(_fixture('open_library_search_dracula.json'));
      }
      return http.Response('not found', 404);
    });

Widget _app(
  Widget home, {
  required MockClient client,
  ThemeMode mode = ThemeMode.light,
  List<Book> books = const [],
}) {
  final discoverHttp = DiscoverHttp(client: client);
  return ProviderScope(
    overrides: [
      discoverHttpProvider.overrideWithValue(discoverHttp),
      discoverRepositoryProvider.overrideWithValue(
        DiscoverRepository([
          StandardEbooksCatalog(discoverHttp),
          GutenbergCatalog(discoverHttp),
          OpenLibraryCatalog(discoverHttp),
        ]),
      ),
      booksProvider.overrideWith((ref) => Stream.value(books)),
    ],
    child: MaterialApp(
      theme: brutalTheme(dark: false),
      darkTheme: brutalTheme(dark: true),
      themeMode: mode,
      home: home,
    ),
  );
}

void _phoneSize(WidgetTester tester, {double width = 320}) {
  tester.view.physicalSize = Size(width * 2, 640 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('browses Standard Ebooks at 320 dp in light and dark', (
    tester,
  ) async {
    _phoneSize(tester);
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.pumpWidget(
        _app(const DiscoverScreen(), client: _fixtureClient(), mode: mode),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Frankenstein'), findsWidgets);
      expect(find.text('Mary Shelley'), findsOneWidget);
      expect(find.text('Popular'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Load more'),
        300,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      expect(find.text('Load more'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('switches source and shelf', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(const DiscoverScreen(), client: _fixtureClient()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Project Gutenberg'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pride and Prejudice'), findsWidgets);
    expect(find.text('Jane Austen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('searches every library and merges duplicates', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(const DiscoverScreen(), client: _fixtureClient()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'dracula');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Results for “dracula”'), findsOneWidget);
    // Standard Ebooks, Gutenberg and Open Library all have "Dracula" by
    // Bram Stoker: it is shown as one card. Each card shows its title twice
    // while covers load (placeholder and caption).
    expect(find.text('Dracula'), findsNWidgets(2));
    expect(find.text("Dracula's Guest"), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an offline state with a retry', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(const DiscoverScreen(), client: _fixtureClient(offline: true)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('book details show size, download and in-library state', (
    tester,
  ) async {
    _phoneSize(tester);
    const book = DiscoverBook(
      source: DiscoverSource.standardEbooks,
      id: '/ebooks/bram-stoker/dracula',
      title: 'Dracula',
      authors: ['Bram Stoker'],
      description: 'An ancient undead monster terrorizes Victorian London.',
      subjects: ['Horror'],
      download: DownloadOption(
        urls: ['https://standardebooks.org/x.epub?source=download'],
        format: BookFormat.epub,
        sizeBytes: 633867,
      ),
    );
    await tester.pumpWidget(
      _app(const DiscoverBookScreen(book: book), client: _fixtureClient()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Download EPUB · 620 KB'), findsOneWidget);
    expect(find.text('About this book'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final owned = Book(
      id: 9,
      title: 'Dracula',
      author: 'Bram Stoker',
      filePath: '/books/dracula.epub',
      fileHash: 'h',
      bookKey: 'dracula|bram-stoker',
      shelf: 'wantToRead',
      addedAt: DateTime(2026),
      progressPercent: 0,
      isFinished: false,
      changedAt: 0,
      stateChangedAt: 0,
      dirty: false,
      deleted: false,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(
        const DiscoverBookScreen(book: book),
        client: _fixtureClient(),
        books: [owned],
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('In your library'), findsOneWidget);
    expect(find.text('Read now'), findsOneWidget);
  });
}
