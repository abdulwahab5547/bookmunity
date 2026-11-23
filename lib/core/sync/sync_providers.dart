import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import 'current_user.dart';
import 'firestore_sync_store.dart';
import 'remote_store.dart';
import 'sync_engine.dart';

export 'current_user.dart';

/// The signed-in account's cloud store, or null when signed out or when
/// Firebase is not available (tests, Linux).
final syncStoreProvider = Provider<SyncStore?>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null || Firebase.apps.isEmpty) return null;
  return FirestoreSyncStore(FirebaseFirestore.instance, uid);
});

/// Runs library sync for the signed-in account while it is watched (the
/// auth gate watches it). Pending changes are flushed when the app goes to
/// the background.
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final store = ref.watch(syncStoreProvider);
  final database = ref.watch(databaseProvider).valueOrNull;
  if (store == null || database == null || !database.syncEnabled) return null;
  final engine = SyncEngine(database, store);
  var disposed = false;
  final lifecycle = AppLifecycleListener(
    onHide: () => unawaited(engine.flush()),
    onDetach: () => unawaited(engine.flush()),
  );
  ref.onDispose(() {
    disposed = true;
    lifecycle.dispose();
    engine.dispose();
  });
  unawaited(engine.start());
  unawaited(
    engine.initialSync.then((_) async {
      if (disposed) return;
      for (final listener in ref.read(syncRestoredListenersProvider)) {
        try {
          await listener();
        } catch (error) {
          debugPrint('Sync restore listener failed: $error');
        }
      }
    }),
  );
  return engine;
});

/// Completes when the cloud library has been merged in, or after a timeout
/// (offline). Badge checks wait for it so a half-restored library never
/// "unlocks" badges the reader already has.
final syncReadyProvider = FutureProvider<void>((ref) async {
  final engine = ref.watch(syncEngineProvider);
  if (engine == null) return;
  await engine.initialSync.timeout(
    const Duration(seconds: 30),
    onTimeout: () {},
  );
});

/// Called once the cloud copy has been merged in after sign-in, e.g. to
/// re-check badges and refresh the public profile stats. Installed in
/// main.dart so core code does not depend on features.
final syncRestoredListenersProvider = Provider<List<Future<void> Function()>>(
  (ref) => const [],
);

/// Pushes pending changes before the account goes away (sign-out).
Future<void> flushSync(WidgetRef ref) async {
  final engine = ref.read(syncEngineProvider);
  if (engine == null) return;
  await engine.flush().timeout(const Duration(seconds: 5), onTimeout: () {});
}
