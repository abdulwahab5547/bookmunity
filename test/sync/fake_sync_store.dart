import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:bookmunity/core/sync/remote_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for one account's Firestore data. Several engines
/// (devices) can share one store. Mirrors the parts of Firestore and the
/// security rules the sync relies on: server-stamped `syncedAt`, merge
/// writes, atomic batches, `syncedAt >=` queries, and the rule that an
/// update may not move `updatedAt` backwards.
class FakeSyncStore implements SyncStore {
  final Map<String, Map<String, Map<String, Object?>>> collections = {};
  final _listeners = <(String, StreamController<RemoteSnapshot>)>[];
  int _serverClock = 1700000000000;
  int commits = 0;

  /// Return true to reject a write (as the rules would).
  bool Function(RemoteWrite write)? reject;

  /// Collections whose listeners only start answering after [release].
  final Set<String> held = {};
  final _heldSnapshots = <(StreamController<RemoteSnapshot>, RemoteSnapshot)>[];

  Map<String, Map<String, Object?>> docs(String collection) =>
      collections[collection] ?? const {};

  Map<String, Object?>? doc(String collection, String id) =>
      collections[collection]?[id];

  @override
  Stream<RemoteSnapshot> watch(String collection, {DateTime? since}) {
    late final StreamController<RemoteSnapshot> controller;
    controller = StreamController<RemoteSnapshot>(
      onListen: () {
        _listeners.add((collection, controller));
        final initial = RemoteSnapshot([
          for (final entry in docs(collection).entries)
            if (since == null ||
                (entry.value['syncedAt'] as DateTime).compareTo(since) >= 0)
              RemoteDoc(entry.key, _copy(entry.value)),
        ], fromServer: true);
        if (held.contains(collection)) {
          _heldSnapshots.add((controller, initial));
        } else {
          scheduleMicrotask(() => controller.add(initial));
        }
      },
      onCancel: () => _listeners.removeWhere((item) => item.$2 == controller),
    );
    return controller.stream;
  }

  void release() {
    held.clear();
    for (final (controller, snapshot) in _heldSnapshots) {
      if (!controller.isClosed) controller.add(snapshot);
    }
    _heldSnapshots.clear();
  }

  @override
  Future<void> commit(List<RemoteWrite> writes) async {
    commits++;
    for (final write in writes) {
      if (reject?.call(write) ?? false) {
        throw StateError('permission-denied: ${write.collection}/${write.id}');
      }
      final existing = doc(write.collection, write.id);
      final incoming = write.data['updatedAt'];
      final current = existing?['updatedAt'];
      if (incoming is DateTime &&
          current is DateTime &&
          incoming.isBefore(current)) {
        throw StateError('permission-denied: stale ${write.id}');
      }
    }
    final changed = <String, List<RemoteDoc>>{};
    for (final write in writes) {
      final collection = collections.putIfAbsent(write.collection, () => {});
      final stamped = {
        ..._copy(write.data),
        'syncedAt': DateTime.fromMillisecondsSinceEpoch(_serverClock++),
      };
      final next = write.merge && collection[write.id] != null
          ? _merge(collection[write.id]!, stamped)
          : stamped;
      collection[write.id] = next;
      changed
          .putIfAbsent(write.collection, () => [])
          .add(RemoteDoc(write.id, _copy(next)));
    }
    for (final (collection, controller) in List.of(_listeners)) {
      final docs = changed[collection];
      if (docs != null && !held.contains(collection)) {
        controller.add(RemoteSnapshot(docs, fromServer: true));
      }
    }
  }

  static Map<String, Object?> _merge(
    Map<String, Object?> base,
    Map<String, Object?> update,
  ) {
    final result = _copy(base);
    for (final entry in update.entries) {
      final current = result[entry.key];
      result[entry.key] =
          current is Map<String, Object?> && entry.value is Map<String, Object?>
          ? _merge(current, entry.value as Map<String, Object?>)
          : entry.value;
    }
    return result;
  }

  static Map<String, Object?> _copy(Map<String, Object?> data) => {
    for (final entry in data.entries)
      entry.key: entry.value is Map<String, Object?>
          ? _copy(entry.value as Map<String, Object?>)
          : entry.value is List
          ? List<Object?>.of(entry.value as List)
          : entry.value,
  };
}

/// Lets microtasks, timers and stream events settle.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A minimal valid EPUB.
List<int> epubBytes({
  required String title,
  String author = 'Author',
  String body = 'Hello',
}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'content.opf',
    '<package xmlns="http://www.idpf.org/2007/opf">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>$title</dc:title><dc:creator>$author</dc:creator>'
        '</metadata><manifest><item id="c" href="c.xhtml" '
        'media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="c"/></spine></package>',
  );
  add('c.xhtml', '<html><body><p>$body</p></body></html>');
  return ZipEncoder().encode(archive);
}

/// Points path_provider at [directory] (plugins are not registered in unit
/// tests).
void mockDocumentsDirectory(String directory) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory,
      );
}
