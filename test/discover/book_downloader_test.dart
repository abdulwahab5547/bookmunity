import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bookmunity/core/db/app_database.dart';
import 'package:bookmunity/features/discover/data/book_downloader.dart';
import 'package:bookmunity/features/discover/data/discover_models.dart';
import 'package:bookmunity/features/discover/data/discover_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _zip = Uint8List.fromList([
  0x50,
  0x4B,
  0x03,
  0x04,
  ...List.filled(5000, 7),
]);

http.StreamedResponse _streamed(List<int> bytes, {int status = 200}) {
  final chunks = <List<int>>[
    for (var i = 0; i < bytes.length; i += 1000)
      bytes.sublist(i, i + 1000 > bytes.length ? bytes.length : i + 1000),
  ];
  return http.StreamedResponse(
    Stream.fromIterable(chunks),
    status,
    contentLength: bytes.length,
  );
}

void main() {
  group('BookDownloader', () {
    test('reports progress and returns the bytes', () async {
      final downloader = BookDownloader(
        client: MockClient.streaming((request, _) async {
          expect(request.headers['User-Agent'], startsWith('Bookmunity/1.0'));
          return _streamed(_zip);
        }),
      );
      final progress = <int>[];
      final file = await downloader.download(
        const DownloadOption(
          urls: ['https://a.org/b.epub'],
          format: BookFormat.epub,
        ),
        onProgress: (received, total) {
          progress.add(received);
          expect(total, _zip.length);
        },
      );
      expect(file.bytes, _zip);
      expect(file.url, 'https://a.org/b.epub');
      expect(progress.last, _zip.length);
      expect(progress.length, greaterThan(2));
    });

    test('falls back to the mirror when the main site is down', () async {
      final downloader = BookDownloader(
        client: MockClient.streaming((request, _) async {
          if (request.url.host == 'www.gutenberg.org') {
            return _streamed(
              utf8.encode('<html>Maintenance</html>'),
              status: 503,
            );
          }
          return _streamed(_zip);
        }),
      );
      final file = await downloader.download(
        const DownloadOption(
          urls: [
            'https://www.gutenberg.org/ebooks/84.epub3.images',
            'https://gutenberg.pglaf.org/cache/epub/84/pg84-images-3.epub',
          ],
          format: BookFormat.epub,
        ),
      );
      expect(file.url, contains('pglaf'));
    });

    test('rejects a web page served instead of the book', () async {
      final downloader = BookDownloader(
        client: MockClient.streaming(
          (_, _) async =>
              _streamed(utf8.encode('<!DOCTYPE html><p>Thanks!</p>')),
        ),
      );
      expect(
        downloader.download(
          const DownloadOption(
            urls: ['https://se.org/x.epub'],
            format: BookFormat.epub,
          ),
        ),
        throwsA(
          isA<DiscoverSourceException>().having(
            (e) => e.message,
            'message',
            contains('web page'),
          ),
        ),
      );
    });

    test('can be cancelled mid-download', () async {
      final controller = StreamController<List<int>>();
      final downloader = BookDownloader(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            controller.stream,
            200,
            contentLength: 100000,
          ),
        ),
      );
      final token = DownloadCancelToken();
      final future = downloader.download(
        const DownloadOption(
          urls: ['https://a.org/b.epub'],
          format: BookFormat.epub,
        ),
        cancelToken: token,
        onProgress: (received, _) {
          if (received > 0) token.cancel();
        },
      );
      controller.add(_zip.sublist(0, 1000));
      controller.add(_zip.sublist(1000, 2000));
      await expectLater(future, throwsA(isA<DownloadCancelled>()));
      await controller.close();
    });

    test('accepts PDFs for PDF downloads', () {
      BookDownloader.validate(
        Uint8List.fromList(utf8.encode('%PDF-1.5\n...')),
        BookFormat.pdf,
      );
      expect(
        () => BookDownloader.validate(_zip, BookFormat.pdf),
        throwsA(isA<DiscoverSourceException>()),
      );
    });
  });

  group('LibraryIndex', () {
    Book row({
      required int id,
      String? sourceUrl,
      String bookKey = '',
      String? filePath = '/books/x.epub',
    }) => Book(
      id: id,
      title: 'Dracula',
      author: 'Bram Stoker',
      filePath: filePath,
      fileHash: filePath == null ? null : 'hash$id',
      bookKey: bookKey,
      addedAt: DateTime(2026),
      shelf: 'wantToRead',
      progressPercent: 0,
      sourceUrl: sourceUrl,
      isFinished: false,
      changedAt: 0,
      stateChangedAt: 0,
      dirty: false,
      deleted: false,
    );

    const dracula = DiscoverBook(
      source: DiscoverSource.standardEbooks,
      id: '/ebooks/bram-stoker/dracula',
      title: 'Dracula',
      authors: ['Bram Stoker'],
      download: DownloadOption(
        urls: [
          'https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/'
              'bram-stoker_dracula.epub?source=download',
        ],
        format: BookFormat.epub,
      ),
    );

    test('matches by source URL whatever the query string', () {
      final index = LibraryIndex([
        row(
          id: 1,
          sourceUrl:
              'https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/'
              'bram-stoker_dracula.epub?source=feed',
        ),
      ]);
      expect(index.find(dracula)?.id, 1);
    });

    test('matches by the metadata book key', () {
      final index = LibraryIndex([row(id: 2, bookKey: 'dracula|bram-stoker')]);
      expect(index.find(dracula)?.id, 2);
    });

    test('finds rows without a file, which can be downloaded again', () {
      final index = LibraryIndex([
        row(id: 3, bookKey: 'dracula|bram-stoker', filePath: null),
      ]);
      expect(index.find(dracula)?.filePath, isNull);
    });

    test('does not match other books', () {
      final index = LibraryIndex([row(id: 4, bookKey: 'emma|jane-austen')]);
      expect(index.find(dracula), isNull);
    });
  });
}
