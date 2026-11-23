/// The cloud side of sync, kept behind an interface so the merge logic can
/// be tested against an in-memory store. The Firestore implementation lives
/// in firestore_sync_store.dart. Layout: docs/cloud-data.md.
library;

/// Collections under `users/{uid}/`.
abstract final class SyncCollections {
  static const library = 'library';
  static const readingState = 'readingState';
  static const highlights = 'highlights';
  static const bookmarks = 'bookmarks';
  static const sessions = 'sessions';
  static const badges = 'badges';

  /// Holds the single `settings` document.
  static const private = 'private';

  /// Listened to by the library sync, in apply order.
  static const all = [
    library,
    readingState,
    highlights,
    bookmarks,
    sessions,
    badges,
  ];
}

/// Firestore document ids cannot contain `/`, be `.` or `..`, or look like
/// `__name__`. Book keys are `title-slug|author-slug` or an ISBN, so this
/// rarely changes anything.
String bookDocId(String bookKey) {
  final id = bookKey.replaceAll('/', '_');
  if (id.isEmpty ||
      id == '.' ||
      id == '..' ||
      RegExp(r'^__.*__$').hasMatch(id)) {
    return 'k_$id';
  }
  return id.length > 400 ? id.substring(0, 400) : id;
}

/// A document as seen by the sync code. Timestamps are [DateTime]s; the
/// store converts to and from its own representation.
class RemoteDoc {
  const RemoteDoc(this.id, this.data);

  final String id;
  final Map<String, Object?> data;

  /// When the content was last edited (the merge clock).
  int get updatedAtMs => _ms(data['updatedAt']);

  /// Server time of the last write; used as a pull watermark.
  int get syncedAtMs => _ms(data['syncedAt']);

  bool get deleted => data['deleted'] == true;

  static int _ms(Object? value) =>
      value is DateTime ? value.millisecondsSinceEpoch : 0;
}

class RemoteSnapshot {
  const RemoteSnapshot(this.docs, {required this.fromServer});

  /// Changed documents (all of them on the first snapshot).
  final List<RemoteDoc> docs;

  /// False while the store only answered from its local cache.
  final bool fromServer;
}

class RemoteWrite {
  const RemoteWrite(this.collection, this.id, this.data, {this.merge = false});

  final String collection;
  final String id;

  /// Document fields. The store adds `syncedAt` (server time) itself.
  final Map<String, Object?> data;

  /// Merge into the existing document instead of replacing it.
  final bool merge;
}

abstract class SyncStore {
  /// Live changes in `users/{uid}/{collection}`, limited to documents whose
  /// `syncedAt` is at or after [since] when given.
  Stream<RemoteSnapshot> watch(String collection, {DateTime? since});

  /// Writes atomically. Completes when the server accepted the writes; an
  /// offline store may queue them and complete much later.
  Future<void> commit(List<RemoteWrite> writes);
}
