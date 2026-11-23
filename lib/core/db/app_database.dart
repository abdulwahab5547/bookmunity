import 'dart:math';

import 'package:drift/drift.dart';

import 'database_connection.dart';
import 'file_storage.dart';

part 'app_database.g.dart';

// Sync bookkeeping (schema v6), shared by the synced tables:
// - `changedAt`: when the row was last edited on any device, in milliseconds
//   since the epoch. It becomes `updatedAt` in Firestore and decides merges:
//   the newer side wins.
// - `dirty`: edited locally and not yet handed to Firestore.
// - `deleted`: soft tombstone. The row is hidden from the app, pushed as
//   `deleted: true`, and purged locally once the push is done.
// See docs/cloud-data.md.

class Books extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get author => text().withDefault(const Constant('UNKNOWN'))();
  TextColumn get coverPath => text().nullable()();

  /// Null when the EPUB is not on this device (restored from the cloud, or
  /// the file was removed). The row keeps its progress, highlights and notes.
  TextColumn get filePath => text().nullable()();

  /// SHA-256 of the EPUB. Known for restored books too, so a file already on
  /// disk (shared by hash between accounts) is re-attached automatically.
  TextColumn get fileHash => text().nullable().unique()();
  TextColumn get bookKey => text().withDefault(const Constant(''))();
  TextColumn get shelf => text().withDefault(const Constant('wantToRead'))();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();
  TextColumn get lastCfi => text().nullable()();
  RealColumn get progressPercent => real().withDefault(const Constant(0))();
  IntColumn get totalLocations => integer().nullable()();
  BoolColumn get isFinished => boolean().withDefault(const Constant(false))();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  TextColumn get genre => text().nullable()();
  TextColumn get locationsJson => text().nullable()();

  /// Where the EPUB was downloaded from (Discover), so the file can be
  /// fetched again after a reinstall. Null for books imported from the
  /// device.
  TextColumn get sourceUrl => text().nullable()();

  /// Library fields (shelf, progress, title, ...): `users/{uid}/library`.
  IntColumn get changedAt => integer().withDefault(const Constant(0))();

  /// Reading position (lastCfi, totalLocations): `users/{uid}/readingState`.
  IntColumn get stateChangedAt => integer().withDefault(const Constant(0))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
}

class Highlights extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get remoteId => text().unique().clientDefault(newRemoteId)();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get cfiRange => text()();
  TextColumn get selectedText => text()();
  IntColumn get color => integer().withDefault(const Constant(0))();
  TextColumn get note => text().nullable()();
  TextColumn get chapterTitle => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get changedAt => integer().withDefault(const Constant(0))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
}

class DictionaryCaches extends Table {
  TextColumn get word => text()();
  TextColumn get responseJson => text()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {word};
}

class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get remoteId => text().unique().clientDefault(newRemoteId)();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get cfi => text()();
  TextColumn get label => text().nullable()();
  RealColumn get percent => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get changedAt => integer().withDefault(const Constant(0))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
}

/// One stretch of active reading. Sessions survive book deletion on purpose:
/// streaks and badges describe the reader, not the current library.
/// Sessions are immutable, so they only need `dirty`.
class ReadingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get remoteId => text().unique().clientDefault(newRemoteId)();

  /// Local book id, or 0 when the book is not in this library.
  IntColumn get bookId => integer()();

  /// Identity of the book across devices; filled in on insert.
  TextColumn get bookKey => text().withDefault(const Constant(''))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  IntColumn get durationSeconds => integer()();
  RealColumn get startPercent => real().withDefault(const Constant(0))();
  RealColumn get endPercent => real().withDefault(const Constant(0))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
}

/// Badges are permanent: merging keeps the earliest unlock.
class BadgeUnlocks extends Table {
  TextColumn get badgeId => text()();
  DateTimeColumn get unlockedAt => dateTime()();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {badgeId};
}

/// Remote documents to mark deleted that no longer have a local row, e.g.
/// the old library entry after a metadata refresh changed a book's key.
class SyncTombstones extends Table {
  TextColumn get collection => text()();
  TextColumn get docId => text()();
  TextColumn get bookKey => text()();
  IntColumn get changedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {collection, docId};
}

/// Small key/value store for sync state, e.g. per-collection watermarks.
class SyncMeta extends Table {
  TextColumn get key => text()();
  IntColumn get intValue => integer()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

final _random = Random.secure();

/// Stable, client-generated id for Firestore documents (128 random bits).
String newRemoteId() => [
  for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16),
].map((part) => part.padLeft(2, '0')).join();

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Finds where a book's file (and cover) live on this device, if anywhere.
/// Used to heal paths after a reinstall, an iOS container move, or a file
/// deleted by another account on the same device.
typedef StoredFileResolver =
    Future<({String? filePath, String? coverPath})> Function(
      String fileHash,
      String? filePath,
      String? coverPath,
    );

@DriftDatabase(
  tables: [
    Books,
    Highlights,
    DictionaryCaches,
    Bookmarks,
    ReadingSessions,
    BadgeUnlocks,
    SyncTombstones,
    SyncMeta,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// With [syncEnabled] deletions are soft until the sync service has pushed
  /// them. Without it (no account, tests) they are removed at once.
  AppDatabase(super.e, {this.syncEnabled = false});

  final bool syncEnabled;

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 3) {
        await m.addColumn(books, books.bookKey);
      }
      if (from < 4) {
        await m.addColumn(books, books.genre);
        await m.addColumn(books, books.locationsJson);
        await m.createTable(bookmarks);
        await m.createTable(readingSessions);
        await m.createTable(badgeUnlocks);
      }
      if (from < 5) {
        await m.addColumn(books, books.sourceUrl);
      }
      if (from < 6) {
        await _migrateToV6(m, from);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Adds sync columns. Every existing row starts dirty so the first signed
  /// in launch uploads the whole local library; `changedAt` is backfilled
  /// from the row's own dates so a newer copy in the cloud still wins.
  Future<void> _migrateToV6(Migrator m, int from) async {
    const randomId = CustomExpression<String>('lower(hex(randomblob(16)))');
    await m.alterTable(
      TableMigration(
        books,
        newColumns: [
          books.changedAt,
          books.stateChangedAt,
          books.dirty,
          books.deleted,
        ],
        columnTransformer: {
          // Firestore document ids cannot be empty.
          books.bookKey: const CustomExpression<String>(
            "CASE WHEN book_key = '' THEN 'file-' || substr(file_hash, 1, 16) "
            'ELSE book_key END',
          ),
          books.changedAt: const CustomExpression<int>(
            'COALESCE(last_opened_at, added_at) * 1000',
          ),
          books.stateChangedAt: const CustomExpression<int>(
            'COALESCE(last_opened_at, added_at) * 1000',
          ),
        },
      ),
    );
    await m.alterTable(
      TableMigration(
        highlights,
        newColumns: [
          highlights.remoteId,
          highlights.changedAt,
          highlights.dirty,
          highlights.deleted,
        ],
        columnTransformer: {
          highlights.remoteId: randomId,
          highlights.changedAt: const CustomExpression<int>(
            'updated_at * 1000',
          ),
        },
      ),
    );
    await m.alterTable(
      TableMigration(
        bookmarks,
        newColumns: [
          bookmarks.remoteId,
          bookmarks.changedAt,
          bookmarks.dirty,
          bookmarks.deleted,
        ],
        columnTransformer: {
          bookmarks.remoteId: randomId,
          bookmarks.changedAt: const CustomExpression<int>('created_at * 1000'),
        },
      ),
    );
    await m.alterTable(
      TableMigration(
        readingSessions,
        newColumns: [
          readingSessions.remoteId,
          readingSessions.bookKey,
          readingSessions.dirty,
        ],
        columnTransformer: {
          readingSessions.remoteId: randomId,
          readingSessions.bookKey: const CustomExpression<String>(
            "COALESCE((SELECT b.book_key FROM books b WHERE b.id = book_id), '')",
          ),
        },
      ),
    );
    // Before v4 the step above created badge_unlocks with today's columns.
    if (from >= 4) await m.addColumn(badgeUnlocks, badgeUnlocks.dirty);
    await m.createTable(syncTombstones);
    await m.createTable(syncMeta);
  }

  // ------------------------------------------------------------------ books

  Stream<List<Book>> watchBooks() =>
      (select(books)
            ..where((book) => book.deleted.equals(false))
            ..orderBy([(book) => OrderingTerm.desc(book.lastOpenedAt)]))
          .watch();

  Future<List<Book>> getBooks() =>
      (select(books)..where((book) => book.deleted.equals(false))).get();

  /// Includes soft-deleted rows, so an import can revive them instead of
  /// tripping over the unique hash.
  Future<Book?> findBookByHash(String hash) => (select(
    books,
  )..where((book) => book.fileHash.equals(hash))).getSingleOrNull();

  /// The row a re-imported file belongs to: same [bookKey], no file on this
  /// device yet.
  Future<Book?> findBookMissingFile(String bookKey) =>
      (select(books)
            ..where(
              (book) =>
                  book.bookKey.equals(bookKey) &
                  book.deleted.equals(false) &
                  book.filePath.isNull(),
            )
            ..orderBy([(book) => OrderingTerm.asc(book.id)])
            ..limit(1))
          .getSingleOrNull();

  Future<int> addBook(BooksCompanion book) {
    final now = _nowMs();
    return into(books).insert(
      book.copyWith(
        changedAt: book.changedAt.present ? null : Value(now),
        stateChangedAt: book.stateChangedAt.present ? null : Value(now),
      ),
    );
  }

  /// Attaches an imported file to an existing row (restored from the cloud,
  /// or soft-deleted and imported again). Reading state is kept.
  Future<void> attachBookFile({
    required int id,
    required String filePath,
    required String fileHash,
    required String? coverPath,
    String? sourceUrl,
  }) async {
    final current = await (select(
      books,
    )..where((book) => book.id.equals(id))).getSingle();
    await (update(books)..where((book) => book.id.equals(id))).write(
      BooksCompanion(
        filePath: Value(filePath),
        fileHash: Value(fileHash),
        coverPath: Value(coverPath ?? current.coverPath),
        sourceUrl: Value(current.sourceUrl ?? sourceUrl),
        deleted: const Value(false),
        dirty: const Value(true),
        changedAt: Value(_nowMs()),
      ),
    );
  }

  /// Lets another row take this row's file hash (unique per database).
  Future<void> releaseFileHash(int id) =>
      (update(books)..where((book) => book.id.equals(id))).write(
        const BooksCompanion(fileHash: Value(null)),
      );

  Future<void> updateMetadata({
    required Book book,
    required String title,
    required String author,
    required String bookKey,
    required String? coverPath,
    String? genre,
  }) async {
    await transaction(() async {
      final now = _nowMs();
      await (update(books)..where((item) => item.id.equals(book.id))).write(
        BooksCompanion(
          title: Value(title),
          author: Value(author),
          bookKey: Value(bookKey),
          coverPath: Value(coverPath),
          genre: Value(genre),
          dirty: const Value(true),
          changedAt: Value(now),
          stateChangedAt: Value(now),
        ),
      );
      if (bookKey == book.bookKey || book.bookKey.isEmpty) return;
      // The library document is keyed by bookKey: retire the old one and
      // re-push everything that refers to the book by key.
      await into(syncTombstones).insertOnConflictUpdate(
        SyncTombstonesCompanion.insert(
          collection: 'library',
          docId: book.bookKey,
          bookKey: book.bookKey,
          changedAt: now,
        ),
      );
      await (update(highlights)..where((h) => h.bookId.equals(book.id))).write(
        HighlightsCompanion(dirty: const Value(true), changedAt: Value(now)),
      );
      await (update(bookmarks)..where((b) => b.bookId.equals(book.id))).write(
        BookmarksCompanion(dirty: const Value(true), changedAt: Value(now)),
      );
      await (update(
        readingSessions,
      )..where((s) => s.bookId.equals(book.id))).write(
        ReadingSessionsCompanion(
          bookKey: Value(bookKey),
          dirty: const Value(true),
        ),
      );
    });
  }

  Stream<Book?> watchBook(int id) =>
      (select(books)
            ..where((book) => book.id.equals(id) & book.deleted.equals(false)))
          .watchSingleOrNull();

  /// Heals file paths: re-attaches files found on disk by hash and clears
  /// paths whose file is gone, so the library shows "Not on this device".
  Future<int> reconcileFiles(StoredFileResolver resolve) async {
    var changed = 0;
    final rows =
        await (select(books)..where(
              (book) => book.deleted.equals(false) & book.fileHash.isNotNull(),
            ))
            .get();
    for (final book in rows) {
      final found = await resolve(
        book.fileHash!,
        book.filePath,
        book.coverPath,
      );
      if (found.filePath == book.filePath &&
          found.coverPath == book.coverPath) {
        continue;
      }
      changed++;
      // Local-only fields: not a library change, so no sync bump.
      await (update(books)..where((item) => item.id.equals(book.id))).write(
        BooksCompanion(
          filePath: Value(found.filePath),
          coverPath: Value(found.coverPath),
        ),
      );
    }
    return changed;
  }

  // ------------------------------------------------------------- highlights

  Stream<List<Highlight>> watchHighlights(int bookId) =>
      (select(highlights)
            ..where(
              (highlight) =>
                  highlight.bookId.equals(bookId) &
                  highlight.deleted.equals(false),
            )
            ..orderBy([(highlight) => OrderingTerm.desc(highlight.createdAt)]))
          .watch();

  Future<List<Highlight>> getHighlights(int bookId) =>
      (select(highlights)..where(
            (highlight) =>
                highlight.bookId.equals(bookId) &
                highlight.deleted.equals(false),
          ))
          .get();

  Future<Highlight?> getHighlight(int id) => (select(
    highlights,
  )..where((highlight) => highlight.id.equals(id))).getSingleOrNull();

  Future<int> countHighlights() => _highlightCount().getSingle();

  Stream<int> watchHighlightCount() => _highlightCount().watchSingle();

  Selectable<int> _highlightCount() {
    final count = highlights.id.count();
    return (selectOnly(highlights)
          ..addColumns([count])
          ..where(highlights.deleted.equals(false)))
        .map((row) => row.read(count) ?? 0);
  }

  /// Inserts a highlight, or revives it (undo after delete) when the
  /// companion carries an existing id.
  Future<int> addHighlight(HighlightsCompanion highlight) =>
      into(highlights).insertOnConflictUpdate(
        highlight.copyWith(
          changedAt: Value(_nowMs()),
          dirty: const Value(true),
          deleted: const Value(false),
        ),
      );

  Future<void> updateHighlightColor(int id, int color) =>
      (update(highlights)..where((highlight) => highlight.id.equals(id))).write(
        HighlightsCompanion(
          color: Value(color),
          updatedAt: Value(DateTime.now()),
          changedAt: Value(_nowMs()),
          dirty: const Value(true),
        ),
      );

  Future<void> deleteHighlight(int id) async {
    if (!syncEnabled) {
      await (delete(highlights)..where((item) => item.id.equals(id))).go();
      return;
    }
    await (update(highlights)..where((item) => item.id.equals(id))).write(
      HighlightsCompanion(
        deleted: const Value(true),
        dirty: const Value(true),
        changedAt: Value(_nowMs()),
      ),
    );
  }

  Future<void> updateHighlightNote(int id, String note) =>
      (update(highlights)..where((highlight) => highlight.id.equals(id))).write(
        HighlightsCompanion(
          note: Value(note.trim().isEmpty ? null : note.trim()),
          updatedAt: Value(DateTime.now()),
          changedAt: Value(_nowMs()),
          dirty: const Value(true),
        ),
      );

  // ------------------------------------------------------- reading state

  /// Saves the reader position. Finishing is sticky: once a book reaches the
  /// end it stays finished even if the reader pages back afterwards.
  Future<void> saveReadingPosition({
    required int bookId,
    required String? cfi,
    required double percent,
    required bool reachedEnd,
  }) async {
    await transaction(() async {
      final current = await (select(
        books,
      )..where((book) => book.id.equals(bookId))).getSingleOrNull();
      if (current == null) return;
      final finishedNow = reachedEnd && !current.isFinished;
      final now = _nowMs();
      await (update(books)..where((book) => book.id.equals(bookId))).write(
        BooksCompanion(
          lastCfi: Value(cfi),
          progressPercent: Value(reachedEnd ? 100 : percent.clamp(0, 100)),
          lastOpenedAt: Value(DateTime.now()),
          shelf: Value(
            current.isFinished || reachedEnd ? 'finished' : 'currentlyReading',
          ),
          isFinished: Value(current.isFinished || reachedEnd),
          finishedAt: finishedNow
              ? Value(DateTime.now())
              : const Value.absent(),
          changedAt: Value(now),
          stateChangedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });
  }

  /// epub.js locations are a regenerable cache and stay on the device.
  Future<void> saveLocations(int bookId, String json) =>
      (update(books)..where((book) => book.id.equals(bookId))).write(
        BooksCompanion(locationsJson: Value(json)),
      );

  // -------------------------------------------------------------- bookmarks

  Stream<List<Bookmark>> watchBookmarks(int bookId) =>
      (select(bookmarks)
            ..where(
              (bookmark) =>
                  bookmark.bookId.equals(bookId) &
                  bookmark.deleted.equals(false),
            )
            ..orderBy([(bookmark) => OrderingTerm.asc(bookmark.percent)]))
          .watch();

  Future<int> addBookmark(BookmarksCompanion bookmark) =>
      into(bookmarks).insert(bookmark.copyWith(changedAt: Value(_nowMs())));

  Future<void> deleteBookmark(int id) async {
    if (!syncEnabled) {
      await (delete(bookmarks)..where((item) => item.id.equals(id))).go();
      return;
    }
    await (update(bookmarks)..where((item) => item.id.equals(id))).write(
      BookmarksCompanion(
        deleted: const Value(true),
        dirty: const Value(true),
        changedAt: Value(_nowMs()),
      ),
    );
  }

  // --------------------------------------------------------------- sessions

  Future<void> addReadingSession(ReadingSessionsCompanion session) async {
    var row = session;
    if (!row.bookKey.present) {
      final book = await (select(
        books,
      )..where((book) => book.id.equals(row.bookId.value))).getSingleOrNull();
      row = row.copyWith(bookKey: Value(book?.bookKey ?? ''));
    }
    await into(readingSessions).insert(row);
  }

  Future<List<ReadingSession>> getReadingSessions() => (select(
    readingSessions,
  )..orderBy([(session) => OrderingTerm.asc(session.startedAt)])).get();

  Stream<List<ReadingSession>> watchReadingSessions() =>
      select(readingSessions).watch();

  // ----------------------------------------------------------------- badges

  Future<List<BadgeUnlock>> getBadgeUnlocks() => select(badgeUnlocks).get();

  Stream<List<BadgeUnlock>> watchBadgeUnlocks() => select(badgeUnlocks).watch();

  Future<void> unlockBadges(Iterable<String> badgeIds, DateTime at) async {
    await batch((batch) {
      batch.insertAll(
        badgeUnlocks,
        badgeIds.map(
          (id) => BadgeUnlocksCompanion.insert(badgeId: id, unlockedAt: at),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  // ------------------------------------------------------------- dictionary

  Future<String?> cachedDefinition(String word) async {
    final row = await (select(
      dictionaryCaches,
    )..where((entry) => entry.word.equals(word))).getSingleOrNull();
    return row?.responseJson;
  }

  Future<void> cacheDefinition(String word, String json) =>
      into(dictionaryCaches).insertOnConflictUpdate(
        DictionaryCachesCompanion.insert(
          word: word,
          responseJson: json,
          cachedAt: DateTime.now(),
        ),
      );

  // ------------------------------------------------------------- deletion

  /// Removes a book with its highlights and bookmarks, and its file from
  /// this device. Reading sessions and badges stay.
  Future<void> deleteBook(Book book) async {
    await transaction(() async {
      if (syncEnabled) {
        final now = _nowMs();
        await (update(
          highlights,
        )..where((item) => item.bookId.equals(book.id))).write(
          HighlightsCompanion(
            deleted: const Value(true),
            dirty: const Value(true),
            changedAt: Value(now),
          ),
        );
        await (update(
          bookmarks,
        )..where((item) => item.bookId.equals(book.id))).write(
          BookmarksCompanion(
            deleted: const Value(true),
            dirty: const Value(true),
            changedAt: Value(now),
          ),
        );
        await (update(books)..where((item) => item.id.equals(book.id))).write(
          BooksCompanion(
            deleted: const Value(true),
            dirty: const Value(true),
            changedAt: Value(now),
            filePath: const Value(null),
            coverPath: const Value(null),
          ),
        );
      } else {
        await (delete(
          highlights,
        )..where((item) => item.bookId.equals(book.id))).go();
        await (delete(
          bookmarks,
        )..where((item) => item.bookId.equals(book.id))).go();
        await (delete(books)..where((item) => item.id.equals(book.id))).go();
      }
      if (book.filePath != null) await deleteStoredFile(book.filePath!);
      if (book.coverPath != null) await deleteStoredFile(book.coverPath!);
    });
  }

  Future<void> updateShelf(Book book, String shelf) =>
      (update(books)..where((item) => item.id.equals(book.id))).write(
        BooksCompanion(
          shelf: Value(shelf),
          isFinished: Value(shelf == 'finished'),
          finishedAt: Value(shelf == 'finished' ? DateTime.now() : null),
          progressPercent: shelf == 'finished'
              ? const Value(100)
              : const Value.absent(),
          changedAt: Value(_nowMs()),
          dirty: const Value(true),
        ),
      );
}

/// Opens the library database. Each account gets its own file so data never
/// leaks between accounts; [uid] null is the signed-out/offline database.
Future<AppDatabase> openDatabase({String? uid}) async {
  return AppDatabase(
    await createDatabaseExecutor(uid: uid),
    syncEnabled: uid != null,
  );
}
