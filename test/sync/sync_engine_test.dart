import 'dart:io';

import 'package:bookmunity/core/db/app_database.dart';
import 'package:bookmunity/core/db/database_connection_io.dart';
import 'package:bookmunity/core/db/file_storage_io.dart';
import 'package:bookmunity/core/import/epub_import_service.dart';
import 'package:bookmunity/core/sync/remote_store.dart';
import 'package:bookmunity/core/sync/sync_engine.dart';
import 'package:bookmunity/features/achievements/data/achievement_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_store.dart';

/// A device: its own database and sync engine against a shared store.
class Device {
  Device(this.store, {this.resolve})
    : db = AppDatabase(NativeDatabase.memory(), syncEnabled: true);

  final FakeSyncStore store;
  final StoredFileResolver? resolve;
  final AppDatabase db;
  late final SyncEngine engine = SyncEngine(
    db,
    store,
    resolveFiles: resolve,
    fastDelay: const Duration(milliseconds: 10),
    slowDelay: const Duration(milliseconds: 300),
    initialPushDelay: const Duration(milliseconds: 50),
    commitTimeout: const Duration(seconds: 2),
  );

  Future<void> connect() async {
    await engine.start();
    await engine.initialSync.timeout(const Duration(seconds: 5));
    await settle();
  }

  Future<void> close() async {
    engine.dispose();
    await db.close();
  }

  Future<Book> book() async => (await db.getBooks()).single;
}

final _now = DateTime(2026, 11, 20, 21);

/// A reader with history: a finished book, a book in progress with a
/// highlight, note and bookmark, five days of sessions and earned badges.
Future<void> seedLibrary(AppDatabase db) async {
  final dune = await db.addBook(
    BooksCompanion.insert(
      title: 'Dune',
      author: const Value('Frank Herbert'),
      filePath: const Value('/device/books/dune.epub'),
      fileHash: const Value('hash-dune'),
      bookKey: const Value('dune|frank-herbert'),
      genre: const Value('Science Fiction'),
      sourceUrl: const Value('https://example.org/dune.epub'),
      addedAt: DateTime(2026, 11, 1),
    ),
  );
  final emma = await db.addBook(
    BooksCompanion.insert(
      title: 'Emma',
      author: const Value('Jane Austen'),
      filePath: const Value('/device/books/emma.epub'),
      fileHash: const Value('hash-emma'),
      bookKey: const Value('emma|jane-austen'),
      addedAt: DateTime(2026, 11, 2),
    ),
  );
  await db.saveReadingPosition(
    bookId: dune,
    cfi: 'epubcfi(/6/14!/4/2/1:0)',
    percent: 37.5,
    reachedEnd: false,
  );
  await db.saveReadingPosition(
    bookId: emma,
    cfi: 'epubcfi(/6/99)',
    percent: 100,
    reachedEnd: true,
  );
  await db.addHighlight(
    HighlightsCompanion.insert(
      bookId: dune,
      cfiRange: 'epubcfi(/6/14!/4/2,/1:0,/1:20)',
      selectedText: 'Fear is the mind-killer.',
      color: const Value(2),
      note: const Value('Litany against fear'),
      chapterTitle: const Value('Chapter 1'),
      createdAt: DateTime(2026, 11, 3),
      updatedAt: DateTime(2026, 11, 3),
    ),
  );
  await db.addBookmark(
    BookmarksCompanion.insert(
      bookId: dune,
      cfi: 'epubcfi(/6/12)',
      label: const Value('Arrakis'),
      percent: const Value(30),
      createdAt: DateTime(2026, 11, 3),
    ),
  );
  for (var day = 16; day <= 20; day++) {
    await db.addReadingSession(
      ReadingSessionsCompanion.insert(
        bookId: day.isEven ? dune : emma,
        startedAt: DateTime(2026, 11, day, 20),
        endedAt: DateTime(2026, 11, day, 20, 30),
        durationSeconds: 1800,
        startPercent: Value(day * 1.0),
        endPercent: Value(day * 2.0),
      ),
    );
  }
  await AchievementService(db).evaluate(now: _now);
}

void main() {
  late FakeSyncStore store;
  final devices = <Device>[];

  Device device({StoredFileResolver? resolve}) {
    final created = Device(store, resolve: resolve);
    devices.add(created);
    return created;
  }

  setUp(() => store = FakeSyncStore());
  tearDown(() async {
    for (final item in devices) {
      await item.close();
    }
    devices.clear();
  });

  test('first sync uploads the existing local library', () async {
    final phone = device();
    await seedLibrary(phone.db);
    await phone.connect();
    await phone.engine.flush();

    final library = store.docs(SyncCollections.library);
    expect(library.keys, {'dune|frank-herbert', 'emma|jane-austen'});
    expect(library['dune|frank-herbert']!['progress'], 37.5);
    expect(library['dune|frank-herbert']!['deleted'], false);
    expect(library['emma|jane-austen']!['shelf'], 'finished');
    expect(
      store.doc(SyncCollections.readingState, 'dune|frank-herbert')!['lastCfi'],
      'epubcfi(/6/14!/4/2/1:0)',
    );
    final highlight = store.docs(SyncCollections.highlights).values.single;
    expect(highlight['note'], 'Litany against fear');
    expect(highlight['bookKey'], 'dune|frank-herbert');
    expect(store.docs(SyncCollections.bookmarks), hasLength(1));
    expect(store.docs(SyncCollections.sessions), hasLength(5));
    expect(store.docs(SyncCollections.badges), isNotEmpty);
    // Nothing is left to push.
    expect(
      (await phone.db.select(phone.db.books).get()).any((b) => b.dirty),
      isFalse,
    );
    expect(
      (await phone.db.select(phone.db.readingSessions).get()).any(
        (s) => s.dirty,
      ),
      isFalse,
    );
  });

  test(
    'delete the app and reinstall: the same library, stats and highlights',
    () async {
      final phone = device();
      await seedLibrary(phone.db);
      await phone.connect();
      await phone.engine.flush();
      final before = await AchievementService(phone.db).summary(now: _now);
      final badgesBefore = {
        for (final badge in await phone.db.getBadgeUnlocks())
          badge.badgeId: badge.unlockedAt,
      };

      // Reinstall: an empty database, same account in the cloud.
      final reinstalled = device();
      expect(await reinstalled.db.getBooks(), isEmpty);
      await reinstalled.connect();

      final books = {
        for (final book in await reinstalled.db.getBooks()) book.bookKey: book,
      };
      expect(books.keys, {'dune|frank-herbert', 'emma|jane-austen'});
      final dune = books['dune|frank-herbert']!;
      expect(dune.title, 'Dune');
      expect(dune.author, 'Frank Herbert');
      expect(dune.genre, 'Science Fiction');
      expect(dune.progressPercent, 37.5);
      expect(dune.shelf, 'currentlyReading');
      expect(dune.lastCfi, 'epubcfi(/6/14!/4/2/1:0)');
      expect(dune.sourceUrl, 'https://example.org/dune.epub');
      // Only the file stays behind.
      expect(dune.filePath, isNull);
      expect(dune.fileHash, 'hash-dune');
      expect(dune.dirty, isFalse);
      final emma = books['emma|jane-austen']!;
      expect(emma.isFinished, isTrue);
      expect(emma.finishedAt, isNotNull);

      final highlight = (await reinstalled.db.getHighlights(dune.id)).single;
      expect(highlight.selectedText, 'Fear is the mind-killer.');
      expect(highlight.note, 'Litany against fear');
      expect(highlight.color, 2);
      expect(highlight.chapterTitle, 'Chapter 1');
      final bookmark =
          (await reinstalled.db.watchBookmarks(dune.id).first).single;
      expect(bookmark.label, 'Arrakis');

      final after = await AchievementService(reinstalled.db).summary(now: _now);
      expect(after.currentStreak, before.currentStreak);
      expect(after.currentStreak, 5);
      expect(after.longestStreak, before.longestStreak);
      expect(after.readingDays, before.readingDays);
      expect(after.totalReadingTime, before.totalReadingTime);
      expect(after.finishedBooks, before.finishedBooks);
      expect(after.earned, before.earned);
      expect({
        for (final badge in await reinstalled.db.getBadgeUnlocks())
          badge.badgeId: badge.unlockedAt,
      }, badgesBefore);
      // Nothing new to award, so no "badge unlocked" burst after a restore.
      expect(
        await AchievementService(reinstalled.db).evaluate(now: _now),
        isEmpty,
      );
      // Restoring writes nothing back.
      final commits = store.commits;
      await reinstalled.engine.flush();
      expect(store.commits, commits);
    },
  );

  test('the newer edit wins, whichever device pushes first', () async {
    final a = device();
    await seedLibrary(a.db);
    await a.connect();
    await a.engine.flush();
    final b = device();
    await b.connect();

    final duneA = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    final duneB = (await b.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    // A edits first but is offline; B edits later.
    await a.db.updateShelf(duneA, 'wantToRead');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.db.updateShelf(duneB, 'finished');

    // The older edit reaches the cloud first; B ignores it.
    await a.engine.flush();
    await settle();
    expect(
      (await b.db.getBooks()).firstWhere((x) => x.title == 'Dune').shelf,
      'finished',
    );
    // B's newer edit then wins everywhere.
    await b.engine.flush();
    await settle();
    expect(
      store.doc(SyncCollections.library, 'dune|frank-herbert')!['shelf'],
      'finished',
    );
    expect(
      (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune').shelf,
      'finished',
    );

    // A stale write is rejected by the cloud and never overwrites.
    await a.db.updateShelf(duneA, 'currentlyReading');
    final row = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    await (a.db.update(a.db.books)..where((x) => x.id.equals(row.id))).write(
      const BooksCompanion(changedAt: Value(1)),
    );
    await a.engine.flush();
    expect(
      store.doc(SyncCollections.library, 'dune|frank-herbert')!['shelf'],
      'finished',
    );
  });

  test('highlight edits and deletes reach the other device', () async {
    final a = device();
    await seedLibrary(a.db);
    await a.connect();
    await a.engine.flush();
    final b = device();
    await b.connect();

    final duneA = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    final highlightA = (await a.db.getHighlights(duneA.id)).single;
    await a.db.updateHighlightNote(highlightA.id, 'edited on the phone');
    await a.engine.flush();
    await settle();
    final duneB = (await b.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    expect(
      (await b.db.getHighlights(duneB.id)).single.note,
      'edited on the phone',
    );

    await a.db.deleteHighlight(highlightA.id);
    expect(await a.db.getHighlights(duneA.id), isEmpty);
    await a.engine.flush();
    await settle();
    // Soft tombstone in the cloud, purged locally once pushed.
    expect(
      store.doc(SyncCollections.highlights, highlightA.remoteId)!['deleted'],
      true,
    );
    expect(await a.db.select(a.db.highlights).get(), isEmpty);
    expect(await b.db.getHighlights(duneB.id), isEmpty);
    expect(await b.db.select(b.db.highlights).get(), isEmpty);
  });

  test('deleting a book removes it everywhere but keeps the stats', () async {
    final a = device();
    await seedLibrary(a.db);
    await a.connect();
    await a.engine.flush();
    final b = device();
    await b.connect();
    final sessionsBefore = (await b.db.getReadingSessions()).length;

    final duneA = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    await a.db.deleteBook(duneA);
    expect((await a.db.getBooks()).map((x) => x.title), ['Emma']);
    await a.engine.flush();
    await settle();

    final library = store.doc(SyncCollections.library, 'dune|frank-herbert')!;
    expect(library['deleted'], true);
    expect(library['title'], 'Dune');
    expect(
      store.docs(SyncCollections.highlights).values.single['deleted'],
      true,
    );
    expect(
      store.docs(SyncCollections.bookmarks).values.single['deleted'],
      true,
    );
    // Purged locally after the push.
    expect(await a.db.select(a.db.books).get(), hasLength(1));
    expect(await a.db.select(a.db.highlights).get(), isEmpty);

    expect((await b.db.getBooks()).map((x) => x.title), ['Emma']);
    expect(await b.db.select(b.db.highlights).get(), isEmpty);
    expect(await b.db.getReadingSessions(), hasLength(sessionsBefore));

    // A fresh install does not bring the deleted book back.
    final fresh = device();
    await fresh.connect();
    expect((await fresh.db.getBooks()).map((x) => x.title), ['Emma']);
  });

  test('highlights that arrive before their book wait for it', () async {
    final a = device();
    await seedLibrary(a.db);
    await a.connect();
    await a.engine.flush();

    store.held.add(SyncCollections.library);
    final b = device();
    await b.engine.start();
    await settle();
    expect(await b.db.getBooks(), isEmpty);
    expect(b.engine.initialSyncDone, isFalse);

    store.release();
    await b.engine.initialSync.timeout(const Duration(seconds: 5));
    await settle();
    final dune = (await b.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    expect(
      (await b.db.getHighlights(dune.id)).single.note,
      'Litany against fear',
    );
    expect(dune.lastCfi, 'epubcfi(/6/14!/4/2/1:0)');
    expect(await b.db.watchBookmarks(dune.id).first, hasLength(1));
  });

  test('reading position saves are throttled into few writes', () async {
    final a = device();
    await seedLibrary(a.db);
    await a.connect();
    await a.engine.flush();
    final dune = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
    final before = store.commits;

    for (var i = 0; i < 20; i++) {
      await a.db.saveReadingPosition(
        bookId: dune.id,
        cfi: 'epubcfi(/6/$i)',
        percent: 40 + i / 10,
        reachedEnd: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.commits, before, reason: 'position saves wait');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.commits, before + 1);
    expect(
      store.doc(SyncCollections.readingState, 'dune|frank-herbert')!['lastCfi'],
      'epubcfi(/6/19)',
    );

    // Other edits go out quickly.
    await a.db.addBookmark(
      BookmarksCompanion.insert(
        bookId: dune.id,
        cfi: 'epubcfi(/6/30)',
        createdAt: DateTime(2026, 11, 21),
      ),
    );
    await settle(3);
    expect(store.commits, before + 2);
  });

  test('a rejected document does not block the rest of the batch', () async {
    final a = device();
    await seedLibrary(a.db);
    store.reject = (write) => write.collection == SyncCollections.bookmarks;
    await a.connect();
    await a.engine.flush();
    expect(store.docs(SyncCollections.library), hasLength(2));
    expect(store.docs(SyncCollections.highlights), hasLength(1));
    expect(store.docs(SyncCollections.bookmarks), isEmpty);
    // Still pending for a later retry.
    expect((await a.db.select(a.db.bookmarks).get()).single.dirty, isTrue);

    store.reject = null;
    await a.engine.flush();
    expect(store.docs(SyncCollections.bookmarks), hasLength(1));
  });

  test('badges keep the earliest unlock across devices', () async {
    final a = device();
    final b = device();
    await a.connect();
    await b.connect();
    await b.db.unlockBadges(['first_session'], DateTime(2026, 5, 2));
    await a.db.unlockBadges(['first_session'], DateTime(2026, 5, 1));
    await b.engine.flush();
    await settle();
    await a.engine.flush();
    await settle();
    await b.engine.flush();
    await settle();
    for (final item in [a, b]) {
      expect(
        (await item.db.getBadgeUnlocks()).single.unlockedAt,
        DateTime(2026, 5, 1),
      );
    }
    expect(
      store.doc(SyncCollections.badges, 'first_session')!['unlockedAt'],
      DateTime(2026, 5, 1),
    );
  });

  test(
    'a metadata refresh that changes the key retires the old entry',
    () async {
      final a = device();
      await seedLibrary(a.db);
      await a.connect();
      await a.engine.flush();
      final dune = (await a.db.getBooks()).firstWhere((x) => x.title == 'Dune');
      await a.db.updateMetadata(
        book: dune,
        title: 'Dune',
        author: 'Frank Herbert',
        bookKey: '9780441013593',
        coverPath: null,
      );
      await a.engine.flush();
      expect(
        store.doc(SyncCollections.library, 'dune|frank-herbert')!['deleted'],
        true,
      );
      expect(
        store.doc(SyncCollections.library, '9780441013593')!['deleted'],
        false,
      );
      expect(
        store.docs(SyncCollections.highlights).values.single['bookKey'],
        '9780441013593',
      );
      final fresh = device();
      await fresh.connect();
      final books = await fresh.db.getBooks();
      expect(books.map((x) => x.bookKey).toSet(), {
        '9780441013593',
        'emma|jane-austen',
      });
      final restored = books.firstWhere((x) => x.title == 'Dune');
      expect(await fresh.db.getHighlights(restored.id), hasLength(1));
    },
  );

  group('files', () {
    late Directory phoneDir;
    late Directory tabletDir;

    setUp(() async {
      phoneDir = await Directory.systemTemp.createTemp('bookmunity-phone');
      tabletDir = await Directory.systemTemp.createTemp('bookmunity-tablet');
    });
    tearDown(() async {
      await phoneDir.delete(recursive: true);
      await tabletDir.delete(recursive: true);
    });

    Future<Device> phoneWithImportedBook(List<int> bytes) async {
      mockDocumentsDirectory(phoneDir.path);
      final phone = device(resolve: resolveStoredFiles);
      final result = await EpubImportService(phone.db).importBytes(bytes);
      expect(result.duplicate, isFalse);
      final book = await phone.book();
      await phone.db.addHighlight(
        HighlightsCompanion.insert(
          bookId: book.id,
          cfiRange: 'epubcfi(/6/2,/1:0,/1:5)',
          selectedText: 'Hello',
          note: const Value('kept'),
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      await phone.db.saveReadingPosition(
        bookId: book.id,
        cfi: 'epubcfi(/6/2)',
        percent: 55,
        reachedEnd: false,
      );
      await phone.connect();
      await phone.engine.flush();
      return phone;
    }

    test('re-importing attaches the file to the restored book', () async {
      final bytes = epubBytes(title: 'Walden', author: 'Henry Thoreau');
      await phoneWithImportedBook(bytes);

      mockDocumentsDirectory(tabletDir.path);
      final tablet = device(resolve: resolveStoredFiles);
      await tablet.connect();
      final restored = await tablet.book();
      expect(restored.filePath, isNull, reason: 'not on this device');
      expect(restored.progressPercent, 55);

      final result = await EpubImportService(tablet.db).importBytes(bytes);
      expect(result.reattached, isTrue);
      expect(result.duplicate, isFalse);
      final books = await tablet.db.getBooks();
      expect(books, hasLength(1), reason: 'no duplicate row');
      final book = books.single;
      expect(book.id, restored.id);
      expect(book.filePath, startsWith(tabletDir.path));
      expect(File(book.filePath!).existsSync(), isTrue);
      expect(book.progressPercent, 55);
      expect(book.lastCfi, 'epubcfi(/6/2)');
      expect((await tablet.db.getHighlights(book.id)).single.note, 'kept');

      // Importing it again now is a plain duplicate.
      final again = await EpubImportService(tablet.db).importBytes(bytes);
      expect(again.duplicate, isTrue);
    });

    test('a different file of the same book attaches by bookKey', () async {
      await phoneWithImportedBook(
        epubBytes(title: 'Walden', author: 'Henry Thoreau', body: 'v1'),
      );
      mockDocumentsDirectory(tabletDir.path);
      final tablet = device(resolve: resolveStoredFiles);
      await tablet.connect();
      final restored = await tablet.book();

      final result = await EpubImportService(tablet.db).importBytes(
        epubBytes(title: 'Walden', author: 'Henry Thoreau', body: 'v2'),
      );
      expect(result.reattached, isTrue);
      final book = await tablet.book();
      expect(book.id, restored.id);
      expect(book.filePath, isNotNull);
      expect(book.fileHash, isNot(restored.fileHash));
      expect(await tablet.db.getHighlights(book.id), hasLength(1));

      // The new hash syncs so other devices can find the file.
      await tablet.engine.flush();
      expect(
        store.doc(SyncCollections.library, book.bookKey)!['fileHash'],
        book.fileHash,
      );
    });

    test('"Import file" attaches even when the key differs', () async {
      await phoneWithImportedBook(epubBytes(title: 'Walden'));
      mockDocumentsDirectory(tabletDir.path);
      final tablet = device(resolve: resolveStoredFiles);
      await tablet.connect();
      final restored = await tablet.book();
      final result = await EpubImportService(
        tablet.db,
      ).reattachBytes(restored, epubBytes(title: 'Walden (Annotated)'));
      expect(result.reattached, isTrue);
      final book = await tablet.book();
      expect(book.id, restored.id);
      expect(book.title, 'Walden', reason: 'library entry unchanged');
      expect(book.filePath, isNotNull);
    });

    test('a file already on the device is picked up by hash', () async {
      await phoneWithImportedBook(epubBytes(title: 'Walden'));
      // Same device (e.g. another account, or the database was lost but
      // the books folder survived).
      final again = device(resolve: resolveStoredFiles);
      await again.connect();
      final book = await again.book();
      expect(book.filePath, startsWith(phoneDir.path));
    });
  });

  test('each account has its own database file', () async {
    final directory = await Directory.systemTemp.createTemp('bookmunity-acct');
    addTearDown(() => directory.delete(recursive: true));
    mockDocumentsDirectory(directory.path);

    // A library from before accounts had their own files.
    final legacy = AppDatabase(
      NativeDatabase(File('${directory.path}/bookmunity.sqlite')),
    );
    await legacy.addBook(
      BooksCompanion.insert(
        title: 'Old library book',
        filePath: const Value('/x.epub'),
        fileHash: const Value('legacy'),
        bookKey: const Value('old'),
        addedAt: DateTime(2026),
      ),
    );
    await legacy.close();

    // The first account to sign in adopts it.
    var alice = await openDatabase(uid: 'alice');
    expect(alice.syncEnabled, isTrue);
    expect((await alice.getBooks()).map((b) => b.title), ['Old library book']);
    await alice.close();
    expect(File('${directory.path}/bookmunity.sqlite').existsSync(), isFalse);
    expect(
      File('${directory.path}/${databaseFileName('alice')}').existsSync(),
      isTrue,
    );

    // Another account starts empty and never sees Alice's rows.
    final bob = await openDatabase(uid: 'bob');
    expect(await bob.getBooks(), isEmpty);
    await bob.addBook(
      BooksCompanion.insert(
        title: 'Bob book',
        filePath: const Value('/b.epub'),
        fileHash: const Value('bob'),
        bookKey: const Value('bob'),
        addedAt: DateTime(2026),
      ),
    );
    await bob.close();

    alice = await openDatabase(uid: 'alice');
    expect((await alice.getBooks()).map((b) => b.title), ['Old library book']);
    await alice.close();

    // Bob's cloud data restores into Bob's database only.
    final bobStore = FakeSyncStore();
    final aliceStore = FakeSyncStore();
    final bobDb = await openDatabase(uid: 'bob');
    final bobEngine = SyncEngine(bobDb, bobStore, resolveFiles: null);
    await bobEngine.start();
    await bobEngine.initialSync;
    await bobEngine.flush();
    bobEngine.dispose();
    await bobDb.close();
    expect(bobStore.docs(SyncCollections.library).keys, ['bob']);
    expect(aliceStore.collections, isEmpty);
  });

  test('without sync, deletes are immediate', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seedLibrary(db);
    final dune = (await db.getBooks()).firstWhere((x) => x.title == 'Dune');
    await db.deleteBook(dune);
    expect(await db.select(db.books).get(), hasLength(1));
    expect(await db.select(db.highlights).get(), isEmpty);
  });
}
