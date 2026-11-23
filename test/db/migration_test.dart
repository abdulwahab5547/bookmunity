import 'package:bookmunity/core/db/app_database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generated_migrations/schema.dart';
import '../generated_migrations/schema_v3.dart' as v3;
import '../generated_migrations/schema_v5.dart' as v5;

void main() {
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  for (final from in [3, 4, 5]) {
    test('upgrading v$from -> v6 produces the expected schema', () async {
      final connection = await verifier.startAt(from);
      final database = AppDatabase(connection);
      await verifier.migrateAndValidate(database, 6);
      await database.close();
    });
  }

  test('upgrading v3 -> latest keeps books and highlights', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());
    await old
        .into(old.books)
        .insert(
          v3.BooksCompanion.insert(
            title: 'Alice',
            filePath: '/books/a.epub',
            fileHash: 'hash-a',
            addedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
            progressPercent: const Value(42),
            lastCfi: const Value('epubcfi(/6/4!/4/2/1:0)'),
          ),
        );
    await old
        .into(old.highlights)
        .insert(
          v3.HighlightsCompanion.insert(
            bookId: 1,
            cfiRange: 'epubcfi(/6/4!/4/2,/1:0,/1:5)',
            selectedText: 'Alice',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    await old.close();

    final database = AppDatabase(schema.newConnection());
    final books = await database.getBooks();
    expect(books.single.title, 'Alice');
    expect(books.single.progressPercent, 42);
    expect(books.single.lastCfi, 'epubcfi(/6/4!/4/2/1:0)');
    expect(books.single.genre, isNull);
    // Rows that never had a key get one Firestore can use as a document id.
    expect(books.single.bookKey, 'file-hash-a');
    expect(await database.countHighlights(), 1);
    expect(await database.getReadingSessions(), isEmpty);
    await database.close();
  });

  test('upgrading v5 -> v6 keeps every row and queues it for upload', () async {
    final schema = await verifier.schemaAt(5);
    final old = v5.DatabaseAtV5(schema.newConnection());
    final added = DateTime(2026, 3, 1).millisecondsSinceEpoch ~/ 1000;
    final opened = DateTime(2026, 3, 5).millisecondsSinceEpoch ~/ 1000;
    await old
        .into(old.books)
        .insert(
          v5.BooksCompanion.insert(
            title: 'Dune',
            author: const Value('Frank Herbert'),
            filePath: '/books/d.epub',
            fileHash: 'hash-d',
            bookKey: const Value('dune|frank-herbert'),
            shelf: const Value('currentlyReading'),
            addedAt: added,
            lastOpenedAt: Value(opened),
            progressPercent: const Value(12.5),
            lastCfi: const Value('epubcfi(/6/8)'),
            sourceUrl: const Value('https://example.org/dune.epub'),
          ),
        );
    for (final text in ['spice', 'sand']) {
      await old
          .into(old.highlights)
          .insert(
            v5.HighlightsCompanion.insert(
              bookId: 1,
              cfiRange: 'epubcfi(/6/8,/1:0,/1:5)',
              selectedText: text,
              note: const Value('a note'),
              createdAt: added,
              updatedAt: opened,
            ),
          );
    }
    await old
        .into(old.bookmarks)
        .insert(
          v5.BookmarksCompanion.insert(
            bookId: 1,
            cfi: 'epubcfi(/6/10)',
            createdAt: opened,
          ),
        );
    await old
        .into(old.readingSessions)
        .insert(
          v5.ReadingSessionsCompanion.insert(
            bookId: 1,
            startedAt: opened,
            endedAt: opened + 600,
            durationSeconds: 600,
          ),
        );
    await old
        .into(old.badgeUnlocks)
        .insert(
          v5.BadgeUnlocksCompanion.insert(
            badgeId: 'first_session',
            unlockedAt: opened,
          ),
        );
    await old.close();

    final database = AppDatabase(schema.newConnection());
    final book = (await database.getBooks()).single;
    expect(book.title, 'Dune');
    expect(book.author, 'Frank Herbert');
    expect(book.filePath, '/books/d.epub');
    expect(book.progressPercent, 12.5);
    expect(book.lastCfi, 'epubcfi(/6/8)');
    expect(book.sourceUrl, 'https://example.org/dune.epub');
    expect(book.dirty, isTrue);
    expect(book.deleted, isFalse);
    expect(book.changedAt, opened * 1000);
    expect(book.stateChangedAt, opened * 1000);

    final highlights = await database.getHighlights(book.id);
    expect(highlights.map((h) => h.selectedText).toSet(), {'spice', 'sand'});
    expect(highlights.every((h) => h.note == 'a note'), isTrue);
    expect(highlights.every((h) => h.remoteId.length == 32), isTrue);
    expect(highlights.map((h) => h.remoteId).toSet(), hasLength(2));
    expect(
      highlights.every((h) => h.dirty && h.changedAt == opened * 1000),
      isTrue,
    );

    final bookmark = (await database.watchBookmarks(book.id).first).single;
    expect(bookmark.cfi, 'epubcfi(/6/10)');
    expect(bookmark.remoteId, hasLength(32));
    expect(bookmark.dirty, isTrue);

    final session = (await database.getReadingSessions()).single;
    expect(session.bookKey, 'dune|frank-herbert');
    expect(session.durationSeconds, 600);
    expect(session.remoteId, hasLength(32));
    expect(session.dirty, isTrue);

    final badge = (await database.getBadgeUnlocks()).single;
    expect(badge.badgeId, 'first_session');
    expect(badge.dirty, isTrue);

    // New rows still get their own remote ids after the migration.
    final id = await database.addHighlight(
      HighlightsCompanion.insert(
        bookId: book.id,
        cfiRange: 'c',
        selectedText: 'new',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final fresh = await database.getHighlight(id);
    expect(fresh!.remoteId, hasLength(32));
    expect(highlights.map((h) => h.remoteId), isNot(contains(fresh.remoteId)));
    await database.close();
  });
}
