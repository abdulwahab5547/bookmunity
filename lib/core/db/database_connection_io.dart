import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

/// One SQLite file per account (`bookmunity_<uid>.sqlite`); `uid` null is
/// the signed-out database (`bookmunity.sqlite`).
///
/// Before accounts had their own files everything lived in
/// `bookmunity.sqlite`. The first account to sign in on this version adopts
/// that file, so its library is kept and uploaded to the cloud.
Future<QueryExecutor> createDatabaseExecutor({String? uid}) async {
  final directory = await getApplicationDocumentsDirectory();
  final legacy = File('${directory.path}/bookmunity.sqlite');
  if (uid == null) return NativeDatabase.createInBackground(legacy);

  final file = File('${directory.path}/${databaseFileName(uid)}');
  if (!await file.exists() && await legacy.exists()) {
    await legacy.rename(file.path);
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final companion = File('${legacy.path}$suffix');
      if (await companion.exists()) {
        await companion.rename('${file.path}$suffix');
      }
    }
  }
  return NativeDatabase.createInBackground(file);
}

/// File name for an account's database. Firebase uids are alphanumeric;
/// anything else is replaced so the name is always a plain file.
String databaseFileName(String uid) =>
    'bookmunity_${uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.sqlite';
