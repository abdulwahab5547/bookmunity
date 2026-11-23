// Drift's WebDatabase is the stable compatibility backend for this target.
// ignore_for_file: deprecated_member_use, experimental_member_use

import 'package:drift/web.dart';

/// One IndexedDB database per account; see database_connection_io.dart.
Future<WebDatabase> createDatabaseExecutor({String? uid}) async {
  return WebDatabase.withStorage(
    DriftWebStorage.indexedDb(uid == null ? 'bookmunity' : 'bookmunity_$uid'),
  );
}
