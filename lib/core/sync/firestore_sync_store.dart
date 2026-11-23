import 'package:cloud_firestore/cloud_firestore.dart';

import 'remote_store.dart';

/// [SyncStore] on Cloud Firestore under `users/{uid}/`. Firestore's offline
/// persistence (on by default on Android and iOS) queues writes while
/// offline and serves snapshots from its cache.
class FirestoreSyncStore implements SyncStore {
  FirestoreSyncStore(this._firestore, this.uid);

  final FirebaseFirestore _firestore;
  final String uid;

  CollectionReference<Map<String, dynamic>> _collection(String name) =>
      _firestore.collection('users').doc(uid).collection(name);

  @override
  Stream<RemoteSnapshot> watch(String collection, {DateTime? since}) {
    Query<Map<String, dynamic>> query = _collection(collection);
    if (since != null) {
      query = query.where(
        'syncedAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(since),
      );
    }
    return query.snapshots(includeMetadataChanges: true).map((snapshot) {
      final docs = <RemoteDoc>[
        for (final change in snapshot.docChanges)
          // Our own writes come back first with pending metadata; the local
          // row already has them.
          if (change.type != DocumentChangeType.removed &&
              !change.doc.metadata.hasPendingWrites)
            RemoteDoc(change.doc.id, _decode(change.doc.data() ?? const {})),
      ];
      return RemoteSnapshot(docs, fromServer: !snapshot.metadata.isFromCache);
    });
  }

  @override
  Future<void> commit(List<RemoteWrite> writes) {
    final batch = _firestore.batch();
    for (final write in writes) {
      batch.set(
        _collection(write.collection).doc(write.id),
        {..._encode(write.data), 'syncedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: write.merge),
      );
    }
    return batch.commit();
  }

  static Map<String, Object?> _encode(Map<String, Object?> data) => {
    for (final entry in data.entries) entry.key: _encodeValue(entry.value),
  };

  static Object? _encodeValue(Object? value) => switch (value) {
    DateTime() => Timestamp.fromDate(value),
    Map<String, Object?>() => _encode(value),
    _ => value,
  };

  static Map<String, Object?> _decode(Map<String, dynamic> data) => {
    for (final entry in data.entries) entry.key: _decodeValue(entry.value),
  };

  static Object? _decodeValue(Object? value) => switch (value) {
    Timestamp() => value.toDate(),
    Map<String, dynamic>() => _decode(value),
    _ => value,
  };
}
