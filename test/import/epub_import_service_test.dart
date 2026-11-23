import 'dart:convert';
import 'dart:io';

import 'package:bookmunity/core/db/app_database.dart';
import 'package:bookmunity/core/import/epub_import_service.dart';
import 'package:bookmunity/core/import/pdf/book_content.dart';
import 'package:bookmunity/core/import/pdf/epub_writer.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _epub(String title) => const EpubWriter().write(
  EpubBookData(
    title: title,
    author: 'Bram Stoker',
    identifier: 'urn:test:$title',
    chapters: const [
      BookChapter(title: 'One', blocks: [ParagraphBlock('Text.')]),
    ],
  ),
);

void main() {
  late AppDatabase database;
  late Directory documents;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    documents = await Directory.systemTemp.createTemp('bookmunity-import');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => documents.path,
        );
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    await documents.delete(recursive: true);
  });

  test('a downloaded EPUB keeps its source URL and reports its row', () async {
    final service = EpubImportService(database);
    const url =
        'https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/'
        'bram-stoker_dracula.epub?source=download';
    final bytes = _epub('Dracula');
    final result = await service.importBytes(
      bytes,
      filename: 'Dracula.epub',
      sourceUrl: url,
    );
    expect(result.duplicate, isFalse);
    expect(result.bookId, isNotNull);
    final book = (await database.getBooks()).single;
    expect(book.id, result.bookId);
    expect(book.sourceUrl, url);
    expect(book.bookKey, 'dracula|bram-stoker');

    final again = await service.importBytes(bytes, sourceUrl: url);
    expect(again.duplicate, isTrue);
    expect(again.bookId, result.bookId, reason: 'so "Read now" still works');
  });

  test('recognises PDFs and rejects other files', () async {
    expect(EpubImportService.isPdf(utf8.encode('%PDF-1.7\n')), isTrue);
    expect(EpubImportService.isPdf(_epub('X')), isFalse);
    expect(
      () => EpubImportService(database).importBytes(utf8.encode('<html>')),
      throwsA(anything),
    );
  });
}
