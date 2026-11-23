import 'dart:convert';
import 'dart:io';

import 'package:bookmunity/features/discover/data/discover_http.dart';
import 'package:bookmunity/features/discover/data/discover_models.dart';
import 'package:bookmunity/features/discover/data/discover_repository.dart';
import 'package:bookmunity/features/discover/data/gutenberg_catalog.dart';
import 'package:bookmunity/features/discover/data/open_library_catalog.dart';
import 'package:bookmunity/features/discover/data/standard_ebooks_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Trimmed real responses, saved on 2026-11-23.
String fixture(String name) =>
    File('test/fixtures/discover/$name').readAsStringSync();

http.Response utf8Response(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'text/plain; charset=utf-8'},
);

Map<String, dynamic> jsonFixture(String name) =>
    jsonDecode(fixture(name)) as Map<String, dynamic>;

void main() {
  group('Gutenberg (Gutendex)', () {
    test('parses a listing with EPUB links, mirror and covers', () {
      final page = GutenbergCatalog.parsePage(
        jsonFixture('gutendex_popular.json'),
      );
      expect(page.books, hasLength(3));
      expect(page.hasMore, isTrue);
      final pride = page.books.first;
      expect(pride.id, '1342');
      expect(pride.title, 'Pride and Prejudice');
      expect(pride.authors, ['Jane Austen']);
      expect(pride.coverUrl, endsWith('pg1342.cover.medium.jpg'));
      expect(pride.download!.urls, [
        'https://www.gutenberg.org/ebooks/1342.epub3.images',
        'https://gutenberg.pglaf.org/cache/epub/1342/pg1342-images-3.epub',
      ]);
      expect(pride.description, isNot(contains('automatically generated')));
      expect(pride.subjects, contains('Courtship'));
      expect(pride.popularity, greaterThan(1000));
    });

    test('asks Gutendex for public-domain EPUBs only', () async {
      late Uri requested;
      final catalog = GutenbergCatalog(
        DiscoverHttp(
          client: MockClient((request) async {
            requested = request.url;
            return utf8Response(fixture('gutendex_search_dracula.json'));
          }),
        ),
      );
      final page = await catalog.search('dracula');
      expect(requested.queryParameters, containsPair('copyright', 'false'));
      expect(
        requested.queryParameters,
        containsPair('mime_type', 'application/epub'),
      );
      expect(requested.queryParameters['search'], 'dracula');
      expect(page.books.first.title, 'Dracula');
      expect(page.books.first.authors, ['Bram Stoker']);
    });
  });

  group('Standard Ebooks', () {
    test('parses the public new-releases Atom feed', () {
      final page = StandardEbooksCatalog.parseAtom(
        fixture('standard_ebooks_new_releases.xml'),
      );
      expect(page.books, hasLength(2));
      final book = page.books.first;
      expect(book.title, 'Confessions of Zeno');
      expect(book.authors, ['Italo Svevo']);
      expect(book.summary, 'To quit smoking, a man writes his memoirs.');
      expect(book.description, contains('Zeno Cosini'));
      expect(book.description, isNot(contains('<p>')));
      expect(book.download!.primaryUrl, endsWith('.epub?source=download'));
      expect(book.download!.sizeBytes, greaterThan(100000));
      expect(book.coverUrl, startsWith('https://standardebooks.org/'));
      expect(book.subjects.first, 'Fiction');
    });

    test('parses Atom search results and their total', () {
      final page = StandardEbooksCatalog.parseAtom(
        fixture('standard_ebooks_search_dracula.xml'),
      );
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
      final dracula = page.books.single;
      expect(dracula.id, '/ebooks/bram-stoker/dracula');
      expect(
        dracula.download!.primaryUrl,
        'https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/'
        'bram-stoker_dracula.epub?source=download',
      );
      expect(dracula.download!.sizeBytes, 633867);
    });

    test('parses catalogue pages through their schema.org markup', () {
      final page = StandardEbooksCatalog.parseCatalogue(
        fixture('standard_ebooks_popular.html'),
      );
      expect(page.books.map((b) => b.title), [
        'Frankenstein',
        'Pride and Prejudice',
        'Meditations',
      ]);
      expect(page.hasMore, isTrue);
      final frankenstein = page.books.first;
      expect(frankenstein.authors, ['Mary Shelley']);
      expect(
        frankenstein.coverUrl,
        startsWith('https://standardebooks.org/images/covers/'),
      );
      expect(frankenstein.subjects, containsAll(['Horror', 'Science Fiction']));
      // Translations have a third path segment.
      expect(
        page.books.last.download!.primaryUrl,
        'https://standardebooks.org/ebooks/marcus-aurelius/meditations/'
        'george-long/downloads/marcus-aurelius_meditations_george-long.epub'
        '?source=download',
      );
    });

    test('parses subject pages, whose author markup differs', () {
      final page = StandardEbooksCatalog.parseCatalogue(
        fixture('standard_ebooks_subject_horror.html'),
      );
      expect(page.books, hasLength(3));
      expect(page.books.first.title, 'Frankenstein');
      expect(page.books.first.authors, ['Mary Shelley']);
      expect(page.books[1].title, 'Dracula');
    });
  });

  group('Open Library', () {
    test('keeps only public works and remembers their archive items', () {
      final page = OpenLibraryCatalog.parseSearch(
        jsonFixture('open_library_search_dracula.json'),
      );
      expect(page.books, isNotEmpty);
      final dracula = page.books.first;
      expect(dracula.id, '/works/OL85892W');
      expect(dracula.archiveIds.first, 'dracula00stok_8');
      expect(
        dracula.coverUrl,
        'https://covers.openlibrary.org/b/id/12216503-M.jpg',
      );
      expect(dracula.download, isNull, reason: 'resolved in details');
    });

    test('drops borrow-only works', () {
      final page = OpenLibraryCatalog.parseSearch({
        'numFound': 1,
        'docs': [
          {
            'key': '/works/OL1W',
            'title': 'Lent book',
            'ebook_access': 'borrowable',
            'ia': ['lent0000'],
          },
        ],
      });
      expect(page.books, isEmpty);
    });

    test('offers the EPUB of an unrestricted archive item', () {
      final option = OpenLibraryCatalog.pickArchiveFile(
        'dracula00stok_8',
        jsonFixture('archive_public_item.json'),
      );
      expect(option!.format, BookFormat.epub);
      expect(
        option.primaryUrl,
        'https://archive.org/download/dracula00stok_8/dracula00stok_8.epub',
      );
      expect(option.sizeBytes, 6206808);
    });

    test('refuses lending-only archive items', () {
      expect(
        OpenLibraryCatalog.pickArchiveFile(
          'bwb_KU-314-467',
          jsonFixture('archive_restricted_item.json'),
        ),
        isNull,
      );
    });

    test('falls back to a text PDF when there is no EPUB', () {
      final option = OpenLibraryCatalog.pickArchiveFile('scan01', {
        'metadata': {'mediatype': 'texts'},
        'files': [
          {'name': 'scan01_encrypted.pdf', 'format': 'ACS Encrypted PDF'},
          {'name': 'scan01.pdf', 'format': 'Text PDF', 'size': '5000000'},
        ],
      });
      expect(option!.format, BookFormat.pdf);
      expect(option.primaryUrl, endsWith('/scan01/scan01.pdf'));
    });

    test('cleans user input before it reaches the Solr query', () {
      expect(
        OpenLibraryCatalog.sanitizeQuery('dracula) OR (title:*"x'),
        'dracula title x',
      );
    });
  });

  group('unified search', () {
    DiscoverBook book(DiscoverSource source, String title, String author) =>
        DiscoverBook(
          source: source,
          id: '$source/$title',
          title: title,
          authors: [author],
        );

    test('folds the same book from several sources into one entry', () {
      final merged = DiscoverRepository.merge({
        DiscoverSource.gutenberg: [
          book(DiscoverSource.gutenberg, 'Dracula', 'Bram Stoker'),
          book(DiscoverSource.gutenberg, "Dracula's Guest", 'Bram Stoker'),
        ],
        DiscoverSource.openLibrary: [
          book(DiscoverSource.openLibrary, 'Dracula', 'Bram Stoker'),
        ],
        DiscoverSource.standardEbooks: [
          book(DiscoverSource.standardEbooks, 'Dracula', 'Bram Stoker'),
        ],
      });
      expect(merged, hasLength(2));
      expect(merged.first.source, DiscoverSource.standardEbooks);
      expect(merged.first.alsoFrom.map((b) => b.source), [
        DiscoverSource.gutenberg,
        DiscoverSource.openLibrary,
      ]);
      expect(merged[1].title, "Dracula's Guest");
    });

    test('ignores subtitles and leading articles when matching', () {
      expect(
        dedupeTitle('Frankenstein; Or, The Modern Prometheus'),
        dedupeTitle('Frankenstein'),
      );
      expect(dedupeTitle('The Time Machine'), dedupeTitle('Time machine'));
      expect(dedupeAuthor(['Mary Wollstonecraft Shelley']), 'shelley');
    });

    test('reports failed sources and keeps the others', () async {
      final repository = DiscoverRepository([
        GutenbergCatalog(
          DiscoverHttp(
            client: MockClient((_) async => http.Response('down', 503)),
          ),
        ),
        StandardEbooksCatalog(
          DiscoverHttp(
            client: MockClient(
              (_) async =>
                  utf8Response(fixture('standard_ebooks_search_dracula.xml')),
            ),
          ),
        ),
        OpenLibraryCatalog(
          DiscoverHttp(
            client: MockClient(
              (_) async => throw http.ClientException(
                'Failed host lookup: openlibrary.org',
              ),
            ),
          ),
        ),
      ]);
      final result = await repository.searchAll('dracula');
      expect(result.books.single.title, 'Dracula');
      expect(result.errors.keys, {
        DiscoverSource.gutenberg,
        DiscoverSource.openLibrary,
      });
      expect(
        result.errors[DiscoverSource.gutenberg],
        isA<DiscoverSourceException>(),
      );
      expect(
        result.errors[DiscoverSource.openLibrary],
        isA<DiscoverOfflineException>(),
      );
      expect(result.offline, isFalse);
    });
  });

  group('DiscoverHttp', () {
    test('sends a polite User-Agent and caches for the session', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.headers['User-Agent'], startsWith('Bookmunity/1.0'));
        return http.Response('{"ok": true}', 200);
      });
      final discoverHttp = DiscoverHttp(client: client);
      final url = Uri.parse('https://gutendex.com/books/');
      await Future.wait([discoverHttp.getJson(url), discoverHttp.getJson(url)]);
      await discoverHttp.getJson(url);
      expect(calls, 1);
      discoverHttp.clearCache();
      await discoverHttp.getJson(url);
      expect(calls, 2);
    });

    test('turns a maintenance page into a friendly error', () async {
      final discoverHttp = DiscoverHttp(
        client: MockClient((_) async => http.Response('<html>', 503)),
      );
      expect(
        () => discoverHttp.getText(Uri.parse('https://gutendex.com/books/')),
        throwsA(
          isA<DiscoverSourceException>().having(
            (e) => e.message,
            'message',
            'Project Gutenberg is temporarily unavailable.',
          ),
        ),
      );
    });
  });

  test('catalogue names become display names', () {
    expect(displayAuthorName('Austen, Jane'), 'Jane Austen');
    expect(
      displayAuthorName('Wells, H. G. (Herbert George), 1866-1946'),
      'H. G. Wells',
    );
    expect(displayAuthorName('Homer'), 'Homer');
  });
}
