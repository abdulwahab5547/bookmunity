import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../db/file_storage.dart';
import 'remote_store.dart';

/// Two-way sync between the local Drift database (the working store) and
/// the cloud. See docs/cloud-data.md for the layout and rules.
///
/// - Push: rows marked `dirty` are written in batches. Reading-position
///   saves only dirty the book row and are pushed at most every
///   [slowDelay]; anything else goes out after [fastDelay].
/// - Pull: one snapshot listener per collection, limited to documents
///   written since the last watermark.
/// - Merge: per document, the newer `updatedAt` wins. Sessions and badges
///   are immutable facts and are unioned (badges keep the earliest unlock).
/// - Deletes: soft tombstones (`deleted: true`), purged locally once pushed.
class SyncEngine {
  SyncEngine(
    this.db,
    this.store, {
    this.resolveFiles = resolveStoredFiles,
    this.fastDelay = const Duration(seconds: 2),
    this.slowDelay = const Duration(seconds: 20),
    this.initialPushDelay = const Duration(seconds: 15),
    this.commitTimeout = const Duration(seconds: 10),
    this.chunkSize = 400,
  });

  final AppDatabase db;
  final SyncStore store;
  final StoredFileResolver? resolveFiles;
  final Duration fastDelay;
  final Duration slowDelay;

  /// Longest wait for the first server snapshots before local changes are
  /// pushed anyway (e.g. when offline).
  final Duration initialPushDelay;

  /// After this the commit counts as queued by the store's offline cache.
  final Duration commitTimeout;

  /// Firestore allows 500 writes per batch.
  final int chunkSize;

  final _initial = Completer<void>();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _serverSeen = <String>{};

  /// Child documents whose book has not arrived yet, by book key.
  final _waiting = <String, List<(String, RemoteDoc)>>{};
  Future<void> _queue = Future.value();
  Timer? _timer;
  DateTime? _deadline;
  Duration _backoff = const Duration(seconds: 30);
  bool _started = false;
  bool _disposed = false;

  /// Completes once every collection has answered from the server, i.e. the
  /// cloud copy has been merged into the local database.
  Future<void> get initialSync => _initial.future;

  bool get initialSyncDone => _initial.isCompleted;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final collection in SyncCollections.all) {
      final mark = await _watermark(collection);
      if (_disposed) return;
      _subscriptions.add(
        store
            .watch(
              collection,
              since: mark == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(mark),
            )
            .listen(
              (snapshot) => _run(() => _apply(collection, snapshot)),
              onError: (Object error) =>
                  debugPrint('Sync listener $collection failed: $error'),
            ),
      );
    }
    _subscriptions.add(_watchDirty().listen(_onDirty));
    Timer(initialPushDelay, () {
      if (!_initial.isCompleted) _schedule(Duration.zero);
    });
  }

  /// Pushes pending changes now, e.g. when the app goes to the background.
  Future<void> flush() {
    _timer?.cancel();
    _deadline = null;
    return _run(_push);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  // ------------------------------------------------------------ scheduling

  Future<void> _run(Future<void> Function() action) {
    final next = _queue.then((_) => _disposed ? null : _guard(action));
    _queue = next;
    return next;
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      if (!_disposed) debugPrint('Sync failed: $error\n$stack');
    }
  }

  Stream<({int books, int other})> _watchDirty() => db
      .customSelect(
        'SELECT '
        '(SELECT COUNT(*) FROM books WHERE dirty = 1) AS b, '
        '(SELECT COUNT(*) FROM highlights WHERE dirty = 1) + '
        '(SELECT COUNT(*) FROM bookmarks WHERE dirty = 1) + '
        '(SELECT COUNT(*) FROM reading_sessions WHERE dirty = 1) + '
        '(SELECT COUNT(*) FROM badge_unlocks WHERE dirty = 1) + '
        '(SELECT COUNT(*) FROM sync_tombstones) AS o',
        readsFrom: {
          db.books,
          db.highlights,
          db.bookmarks,
          db.readingSessions,
          db.badgeUnlocks,
          db.syncTombstones,
        },
      )
      .watchSingle()
      .map((row) => (books: row.read<int>('b'), other: row.read<int>('o')));

  void _onDirty(({int books, int other}) counts) {
    if (counts.books == 0 && counts.other == 0) return;
    // Don't overwrite the cloud before it has been merged in.
    if (!_initial.isCompleted) return;
    _schedule(counts.other > 0 ? fastDelay : slowDelay);
  }

  /// Throttles pushes: an earlier deadline wins, a later one never delays a
  /// pending push. Frequent position saves therefore cost one push per
  /// [slowDelay] at most.
  void _schedule(Duration delay) {
    if (_disposed) return;
    final deadline = DateTime.now().add(delay);
    if (_deadline != null && !deadline.isBefore(_deadline!)) return;
    _timer?.cancel();
    _deadline = deadline;
    _timer = Timer(delay, () {
      _deadline = null;
      _run(_push);
    });
  }

  // ------------------------------------------------------------------ pull

  Future<int?> _watermark(String collection) async {
    final row = await (db.select(
      db.syncMeta,
    )..where((meta) => meta.key.equals('wm.$collection'))).getSingleOrNull();
    return row?.intValue;
  }

  Future<void> _apply(String collection, RemoteSnapshot snapshot) async {
    var restored = false;
    var latest = 0;
    await db.transaction(() async {
      for (final doc in snapshot.docs) {
        if (doc.syncedAtMs > latest) latest = doc.syncedAtMs;
        if (await _applyDoc(collection, doc)) restored = true;
      }
      if (collection == SyncCollections.library) await _retryWaiting();
    });
    if (restored && resolveFiles != null) {
      await db.reconcileFiles(resolveFiles!);
    }
    await _saveWatermark(collection, latest);
    if (snapshot.fromServer && _serverSeen.add(collection)) {
      if (_serverSeen.length == SyncCollections.all.length &&
          !_initial.isCompleted) {
        _initial.complete();
        _schedule(Duration.zero);
      }
    }
  }

  /// The watermark never passes a document still waiting for its book, so
  /// it is delivered again after a restart.
  Future<void> _saveWatermark(String collection, int latest) async {
    var mark = latest;
    for (final docs in _waiting.values) {
      for (final (waitingCollection, doc) in docs) {
        if (waitingCollection == collection &&
            doc.syncedAtMs > 0 &&
            doc.syncedAtMs < mark) {
          mark = doc.syncedAtMs;
        }
      }
    }
    if (mark == 0) return;
    final current = await _watermark(collection);
    if (current != null && current >= mark) return;
    await db
        .into(db.syncMeta)
        .insertOnConflictUpdate(
          SyncMetaCompanion.insert(key: 'wm.$collection', intValue: mark),
        );
  }

  Future<void> _retryWaiting() async {
    for (final key in _waiting.keys.toList()) {
      if (await _bookByKey(key) == null) continue;
      final docs = _waiting.remove(key)!;
      for (final (collection, doc) in docs) {
        await _applyDoc(collection, doc);
      }
    }
  }

  void _wait(String bookKey, String collection, RemoteDoc doc) =>
      _waiting.putIfAbsent(bookKey, () => []).add((collection, doc));

  /// Returns true when a book row was created (restored).
  Future<bool> _applyDoc(String collection, RemoteDoc doc) async {
    switch (collection) {
      case SyncCollections.library:
        return _applyLibrary(doc);
      case SyncCollections.readingState:
        await _applyReadingState(doc);
      case SyncCollections.highlights:
        await _applyHighlight(doc);
      case SyncCollections.bookmarks:
        await _applyBookmark(doc);
      case SyncCollections.sessions:
        await _applySession(doc);
      case SyncCollections.badges:
        await _applyBadge(doc);
    }
    return false;
  }

  /// The row that represents [bookKey] here: the oldest live one, or a
  /// soft-deleted one when [includeDeleted].
  Future<Book?> _bookByKey(String bookKey, {bool includeDeleted = false}) =>
      (db.select(db.books)
            ..where(
              (book) =>
                  book.bookKey.equals(bookKey) &
                  (includeDeleted
                      ? const Constant(true)
                      : book.deleted.equals(false)),
            )
            ..orderBy([
              (book) => OrderingTerm.asc(book.deleted),
              (book) => OrderingTerm.asc(book.id),
            ])
            ..limit(1))
          .getSingleOrNull();

  Future<bool> _applyLibrary(RemoteDoc doc) async {
    final data = doc.data;
    final key = _string(data['bookKey']);
    if (key == null || key.isEmpty) return false;
    final local = await _bookByKey(key, includeDeleted: true);
    final at = doc.updatedAtMs;
    if (local == null) {
      if (doc.deleted) return false;
      var hash = _string(data['fileHash']);
      if (hash != null && await db.findBookByHash(hash) != null) hash = null;
      await db
          .into(db.books)
          .insert(
            BooksCompanion.insert(
              title: _string(data['title']) ?? key,
              author: Value(_string(data['author']) ?? 'UNKNOWN'),
              filePath: const Value(null),
              fileHash: Value(hash),
              bookKey: Value(key),
              addedAt: _date(data['addedAt']) ?? DateTime.now(),
              shelf: Value(_string(data['shelf']) ?? 'wantToRead'),
              progressPercent: Value(_double(data['progress'])),
              isFinished: Value(data['shelf'] == 'finished'),
              finishedAt: Value(_date(data['finishedAt'])),
              lastOpenedAt: Value(_date(data['lastOpenedAt'])),
              genre: Value(_string(data['genre'])),
              sourceUrl: Value(_string(data['sourceUrl'])),
              changedAt: Value(at),
              dirty: const Value(false),
            ),
          );
      return true;
    }
    if (at <= local.changedAt) return false;
    if (doc.deleted) {
      await _deleteBookRow(local);
      return false;
    }
    var hash = local.fileHash;
    final remoteHash = _string(data['fileHash']);
    if (hash == null &&
        remoteHash != null &&
        await db.findBookByHash(remoteHash) == null) {
      hash = remoteHash;
    }
    await (db.update(
      db.books,
    )..where((book) => book.id.equals(local.id))).write(
      BooksCompanion(
        title: Value(_string(data['title']) ?? local.title),
        author: Value(_string(data['author']) ?? local.author),
        genre: Value(_string(data['genre'])),
        shelf: Value(_string(data['shelf']) ?? local.shelf),
        progressPercent: Value(_double(data['progress'])),
        isFinished: Value(data['shelf'] == 'finished'),
        finishedAt: Value(_date(data['finishedAt'])),
        lastOpenedAt: Value(_date(data['lastOpenedAt'])),
        addedAt: Value(_date(data['addedAt']) ?? local.addedAt),
        sourceUrl: Value(_string(data['sourceUrl']) ?? local.sourceUrl),
        fileHash: Value(hash),
        deleted: const Value(false),
        changedAt: Value(at),
      ),
    );
    return hash != local.fileHash;
  }

  Future<void> _deleteBookRow(Book book) async {
    await (db.delete(db.books)..where((item) => item.id.equals(book.id))).go();
    if (book.filePath != null) await deleteStoredFile(book.filePath!);
    if (book.coverPath != null) await deleteStoredFile(book.coverPath!);
  }

  Future<void> _applyReadingState(RemoteDoc doc) async {
    final key = _string(doc.data['bookKey']);
    if (key == null || key.isEmpty || doc.deleted) return;
    final local = await _bookByKey(key);
    if (local == null) return _wait(key, SyncCollections.readingState, doc);
    if (doc.updatedAtMs <= local.stateChangedAt) return;
    await (db.update(
      db.books,
    )..where((book) => book.id.equals(local.id))).write(
      BooksCompanion(
        lastCfi: Value(_string(doc.data['lastCfi'])),
        totalLocations: Value(_int(doc.data['totalLocations'])),
        stateChangedAt: Value(doc.updatedAtMs),
      ),
    );
  }

  Future<void> _applyHighlight(RemoteDoc doc) async {
    final data = doc.data;
    final local = await (db.select(
      db.highlights,
    )..where((item) => item.remoteId.equals(doc.id))).getSingleOrNull();
    if (local != null && doc.updatedAtMs <= local.changedAt) return;
    if (doc.deleted) {
      if (local != null) {
        await (db.delete(
          db.highlights,
        )..where((item) => item.id.equals(local.id))).go();
      }
      return;
    }
    final key = _string(data['bookKey']) ?? '';
    final book = await _bookByKey(key);
    if (book == null) return _wait(key, SyncCollections.highlights, doc);
    final row = HighlightsCompanion(
      remoteId: Value(doc.id),
      bookId: Value(book.id),
      cfiRange: Value(_string(data['cfiRange']) ?? ''),
      selectedText: Value(_string(data['selectedText']) ?? ''),
      color: Value(_int(data['color']) ?? 0),
      note: Value(_string(data['note'])),
      chapterTitle: Value(_string(data['chapterTitle'])),
      createdAt: Value(_date(data['createdAt']) ?? DateTime.now()),
      updatedAt: Value(DateTime.fromMillisecondsSinceEpoch(doc.updatedAtMs)),
      changedAt: Value(doc.updatedAtMs),
      deleted: const Value(false),
    );
    if (local == null) {
      await db
          .into(db.highlights)
          .insert(row.copyWith(dirty: const Value(false)));
    } else {
      await (db.update(
        db.highlights,
      )..where((item) => item.id.equals(local.id))).write(row);
    }
  }

  Future<void> _applyBookmark(RemoteDoc doc) async {
    final data = doc.data;
    final local = await (db.select(
      db.bookmarks,
    )..where((item) => item.remoteId.equals(doc.id))).getSingleOrNull();
    if (local != null && doc.updatedAtMs <= local.changedAt) return;
    if (doc.deleted) {
      if (local != null) {
        await (db.delete(
          db.bookmarks,
        )..where((item) => item.id.equals(local.id))).go();
      }
      return;
    }
    final key = _string(data['bookKey']) ?? '';
    final book = await _bookByKey(key);
    if (book == null) return _wait(key, SyncCollections.bookmarks, doc);
    final row = BookmarksCompanion(
      remoteId: Value(doc.id),
      bookId: Value(book.id),
      cfi: Value(_string(data['cfi']) ?? ''),
      label: Value(_string(data['label'])),
      percent: Value(_double(data['percent'])),
      createdAt: Value(_date(data['createdAt']) ?? DateTime.now()),
      changedAt: Value(doc.updatedAtMs),
      deleted: const Value(false),
    );
    if (local == null) {
      await db
          .into(db.bookmarks)
          .insert(row.copyWith(dirty: const Value(false)));
    } else {
      await (db.update(
        db.bookmarks,
      )..where((item) => item.id.equals(local.id))).write(row);
    }
  }

  Future<void> _applySession(RemoteDoc doc) async {
    final data = doc.data;
    final local = await (db.select(
      db.readingSessions,
    )..where((item) => item.remoteId.equals(doc.id))).getSingleOrNull();
    final key = _string(data['bookKey']) ?? '';
    final book = key.isEmpty ? null : await _bookByKey(key);
    if (local != null) {
      // Immutable; only the book key can change (metadata refresh).
      if (local.bookKey != key && !local.dirty) {
        await (db.update(
          db.readingSessions,
        )..where((item) => item.id.equals(local.id))).write(
          ReadingSessionsCompanion(
            bookKey: Value(key),
            bookId: Value(book?.id ?? local.bookId),
          ),
        );
      }
      return;
    }
    final startedAt = _date(data['startedAt']);
    final endedAt = _date(data['endedAt']);
    if (startedAt == null || endedAt == null) return;
    await db
        .into(db.readingSessions)
        .insert(
          ReadingSessionsCompanion.insert(
            remoteId: Value(doc.id),
            bookId: book?.id ?? 0,
            bookKey: Value(key),
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: _int(data['durationSeconds']) ?? 0,
            startPercent: Value(_double(data['startPercent'])),
            endPercent: Value(_double(data['endPercent'])),
            dirty: const Value(false),
          ),
        );
  }

  Future<void> _applyBadge(RemoteDoc doc) async {
    final unlockedAt = _date(doc.data['unlockedAt']);
    if (unlockedAt == null) return;
    final local = await (db.select(
      db.badgeUnlocks,
    )..where((item) => item.badgeId.equals(doc.id))).getSingleOrNull();
    if (local == null) {
      await db
          .into(db.badgeUnlocks)
          .insert(
            BadgeUnlocksCompanion.insert(
              badgeId: doc.id,
              unlockedAt: unlockedAt,
              dirty: const Value(false),
            ),
          );
    } else if (unlockedAt.isBefore(local.unlockedAt)) {
      await (db.update(db.badgeUnlocks)
            ..where((item) => item.badgeId.equals(doc.id)))
          .write(BadgeUnlocksCompanion(unlockedAt: Value(unlockedAt)));
    } else if (local.unlockedAt.isBefore(unlockedAt) && !local.dirty) {
      // Ours is earlier: send it back so every device keeps the first one.
      await (db.update(db.badgeUnlocks)
            ..where((item) => item.badgeId.equals(doc.id)))
          .write(const BadgeUnlocksCompanion(dirty: Value(true)));
    }
  }

  // ------------------------------------------------------------------ push

  Future<void> _push() async {
    if (_disposed) return;
    final writes = await _collectWrites();
    if (writes.isEmpty) return;
    var failed = false;
    for (var i = 0; i < writes.length; i += chunkSize) {
      final chunk = writes.sublist(
        i,
        i + chunkSize > writes.length ? writes.length : i + chunkSize,
      );
      if (!await _commit(chunk)) {
        // One bad document must not hold back the rest of the batch.
        for (final write in chunk) {
          if (!await _commit([write])) failed = true;
        }
      }
    }
    await _purge();
    if (failed) {
      _schedule(_backoff);
      final next = _backoff * 2;
      _backoff = next > const Duration(minutes: 15)
          ? const Duration(minutes: 15)
          : next;
    } else {
      _backoff = const Duration(seconds: 30);
    }
  }

  /// Returns false when the store rejected the writes. A commit that is
  /// still pending after [commitTimeout] is queued offline: the rows are
  /// marked clean now and marked dirty again if the store rejects it later.
  Future<bool> _commit(List<_Write> writes) async {
    final future = store.commit([for (final write in writes) write.remote!]);
    try {
      await future.timeout(commitTimeout);
    } on TimeoutException {
      unawaited(
        future.catchError((Object error) async {
          debugPrint('Queued sync write rejected: $error');
          for (final write in writes) {
            await _guard(write.rejected);
          }
        }),
      );
    } catch (error) {
      debugPrint('Sync write rejected: $error');
      return false;
    }
    for (final write in writes) {
      await write.accepted();
    }
    return true;
  }

  /// Removes tombstones that reached the cloud. A deleted book goes once its
  /// highlights and bookmarks have been pushed (the delete cascades).
  Future<void> _purge() async {
    await db.customStatement(
      'DELETE FROM highlights WHERE deleted = 1 AND dirty = 0',
    );
    await db.customStatement(
      'DELETE FROM bookmarks WHERE deleted = 1 AND dirty = 0',
    );
    await db.customStatement(
      'DELETE FROM books WHERE deleted = 1 AND dirty = 0 '
      'AND NOT EXISTS (SELECT 1 FROM highlights h '
      'WHERE h.book_id = books.id AND h.dirty = 1) '
      'AND NOT EXISTS (SELECT 1 FROM bookmarks m '
      'WHERE m.book_id = books.id AND m.dirty = 1)',
    );
  }

  Future<List<_Write>> _collectWrites() async {
    final writes = <_Write>[];
    final keys = <int, String>{};
    for (final book in await db.select(db.books).get()) {
      keys[book.id] = book.bookKey;
    }

    final dirtyBooks = await (db.select(
      db.books,
    )..where((book) => book.dirty.equals(true))).get();
    for (final book in dirtyBooks) {
      writes.addAll(await _bookWrites(book));
    }

    for (final tombstone in await db.select(db.syncTombstones).get()) {
      // Only retire the old document if no live row still uses that key.
      final live = await _bookByKey(tombstone.bookKey);
      writes.add(
        _Write(
          live != null
              ? null
              : RemoteWrite(tombstone.collection, tombstone.docId, {
                  'bookKey': tombstone.bookKey,
                  'deleted': true,
                  'updatedAt': _time(tombstone.changedAt),
                }, merge: true),
          accepted: () =>
              (db.delete(db.syncTombstones)..where(
                    (item) =>
                        item.collection.equals(tombstone.collection) &
                        item.docId.equals(tombstone.docId) &
                        item.changedAt.equals(tombstone.changedAt),
                  ))
                  .go(),
          rejected: () async {},
        ),
      );
    }

    final dirtyHighlights = await (db.select(
      db.highlights,
    )..where((item) => item.dirty.equals(true))).get();
    for (final highlight in dirtyHighlights) {
      writes.add(
        _Write(
          RemoteWrite(SyncCollections.highlights, highlight.remoteId, {
            'bookKey': keys[highlight.bookId] ?? '',
            'cfiRange': _clip(highlight.cfiRange, 2000),
            'selectedText': _clip(highlight.selectedText, 10000),
            'color': highlight.color,
            if (highlight.note != null) 'note': _clip(highlight.note!, 10000),
            if (highlight.chapterTitle != null)
              'chapterTitle': _clip(highlight.chapterTitle!, 500),
            'createdAt': highlight.createdAt,
            'updatedAt': _time(highlight.changedAt),
            'deleted': highlight.deleted,
          }),
          accepted: () => _markClean(
            'highlights',
            'id = ? AND changed_at = ?',
            [highlight.id, highlight.changedAt],
          ),
          rejected: () => _markDirty(
            'highlights',
            'id = ? AND changed_at = ?',
            [highlight.id, highlight.changedAt],
          ),
        ),
      );
    }

    final dirtyBookmarks = await (db.select(
      db.bookmarks,
    )..where((item) => item.dirty.equals(true))).get();
    for (final bookmark in dirtyBookmarks) {
      writes.add(
        _Write(
          RemoteWrite(SyncCollections.bookmarks, bookmark.remoteId, {
            'bookKey': keys[bookmark.bookId] ?? '',
            'cfi': _clip(bookmark.cfi, 2000),
            if (bookmark.label != null) 'label': _clip(bookmark.label!, 500),
            'percent': bookmark.percent,
            'createdAt': bookmark.createdAt,
            'updatedAt': _time(bookmark.changedAt),
            'deleted': bookmark.deleted,
          }),
          accepted: () => _markClean('bookmarks', 'id = ? AND changed_at = ?', [
            bookmark.id,
            bookmark.changedAt,
          ]),
          rejected: () => _markDirty('bookmarks', 'id = ? AND changed_at = ?', [
            bookmark.id,
            bookmark.changedAt,
          ]),
        ),
      );
    }

    final dirtySessions = await (db.select(
      db.readingSessions,
    )..where((item) => item.dirty.equals(true))).get();
    for (final session in dirtySessions) {
      writes.add(
        _Write(
          RemoteWrite(SyncCollections.sessions, session.remoteId, {
            'bookKey': session.bookKey,
            'startedAt': session.startedAt,
            'endedAt': session.endedAt,
            'durationSeconds': session.durationSeconds,
            'startPercent': session.startPercent,
            'endPercent': session.endPercent,
            'updatedAt': DateTime.now(),
          }),
          accepted: () => _markClean(
            'reading_sessions',
            'id = ? AND book_key = ?',
            [session.id, session.bookKey],
          ),
          rejected: () =>
              _markDirty('reading_sessions', 'id = ?', [session.id]),
        ),
      );
    }

    final dirtyBadges = await (db.select(
      db.badgeUnlocks,
    )..where((item) => item.dirty.equals(true))).get();
    for (final badge in dirtyBadges) {
      writes.add(
        _Write(
          RemoteWrite(SyncCollections.badges, badge.badgeId, {
            'badgeId': badge.badgeId,
            'unlockedAt': badge.unlockedAt,
            'updatedAt': DateTime.now(),
          }),
          accepted: () =>
              _markClean('badge_unlocks', 'badge_id = ?', [badge.badgeId]),
          rejected: () =>
              _markDirty('badge_unlocks', 'badge_id = ?', [badge.badgeId]),
        ),
      );
    }
    return [
      for (final write in writes)
        if (write.isNoOp) await write.acceptLocally() else write,
    ].whereType<_Write>().toList();
  }

  Future<List<_Write>> _bookWrites(Book book) async {
    Future<void> clean() => _markClean(
      'books',
      'id = ? AND changed_at = ? AND state_changed_at = ?',
      [book.id, book.changedAt, book.stateChangedAt],
    );
    Future<void> dirty() => _markDirty(
      'books',
      'id = ? AND changed_at = ? AND state_changed_at = ?',
      [book.id, book.changedAt, book.stateChangedAt],
    );
    // Another row with the same key owns the cloud document (a second copy
    // of the same book on this device): keep this one local.
    final owner = await _bookByKey(book.bookKey);
    if (book.bookKey.isEmpty || (owner != null && owner.id != book.id)) {
      return [_Write(null, accepted: clean, rejected: () async {})];
    }
    final id = bookDocId(book.bookKey);
    final library = RemoteWrite(SyncCollections.library, id, {
      'bookKey': book.bookKey,
      'title': _clip(book.title, 500),
      'author': _clip(book.author, 500),
      if (book.genre != null) 'genre': _clip(book.genre!, 100),
      'shelf': book.shelf,
      'progress': book.progressPercent,
      'addedAt': book.addedAt,
      if (book.finishedAt != null) 'finishedAt': book.finishedAt,
      if (book.lastOpenedAt != null) 'lastOpenedAt': book.lastOpenedAt,
      if (book.sourceUrl != null) 'sourceUrl': _clip(book.sourceUrl!, 2000),
      if (book.fileHash != null) 'fileHash': book.fileHash,
      'deleted': book.deleted,
      'updatedAt': _time(book.changedAt),
    });
    return [
      _Write(library, accepted: clean, rejected: dirty),
      if (!book.deleted)
        _Write(
          RemoteWrite(SyncCollections.readingState, id, {
            'bookKey': book.bookKey,
            if (book.lastCfi != null) 'lastCfi': _clip(book.lastCfi!, 2000),
            if (book.totalLocations != null)
              'totalLocations': book.totalLocations,
            'updatedAt': _time(book.stateChangedAt),
          }),
          accepted: () async {},
          rejected: dirty,
        ),
    ];
  }

  Future<void> _markClean(String table, String where, List<Object> args) =>
      db.customUpdate(
        'UPDATE $table SET dirty = 0 WHERE $where',
        variables: [for (final arg in args) Variable(arg)],
        updates: {_tableNamed(table)},
      );

  Future<void> _markDirty(String table, String where, List<Object> args) =>
      db.customUpdate(
        'UPDATE $table SET dirty = 1 WHERE $where',
        variables: [for (final arg in args) Variable(arg)],
        updates: {_tableNamed(table)},
      );

  TableInfo<Table, Object?> _tableNamed(String name) =>
      db.allTables.firstWhere((table) => table.actualTableName == name);
}

/// A pending cloud write and what to do locally once it is accepted (mark
/// clean) or rejected after being queued (mark dirty again). A null
/// [remote] needs no cloud write and is only accepted locally.
class _Write {
  _Write(this.remote, {required this.accepted, required this.rejected});

  final RemoteWrite? remote;
  final Future<void> Function() accepted;
  final Future<void> Function() rejected;

  bool get isNoOp => remote == null;

  Future<_Write?> acceptLocally() async {
    await accepted();
    return null;
  }
}

DateTime _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

String _clip(String value, int max) =>
    value.length > max ? value.substring(0, max) : value;

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is num ? value.toInt() : null;

double _double(Object? value) => value is num ? value.toDouble() : 0;

DateTime? _date(Object? value) => value is DateTime ? value : null;
