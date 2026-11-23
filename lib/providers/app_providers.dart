import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/app_database.dart';
import '../core/db/file_storage.dart';
import '../core/import/epub_import_service.dart';
import '../core/sync/current_user.dart';

/// The signed-in account's library. Each account has its own database file,
/// so switching accounts swaps the whole library.
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final database = await openDatabase(uid: ref.watch(currentUidProvider));
  ref.onDispose(database.close);
  // Show books whose file went missing as "Not on this device".
  await database.reconcileFiles(resolveStoredFiles);
  return database;
});

final importServiceProvider = FutureProvider<EpubImportService>((ref) async {
  final database = await ref.watch(databaseProvider.future);
  return EpubImportService(database);
});

final booksProvider = StreamProvider<List<Book>>((ref) async* {
  final database = await ref.watch(databaseProvider.future);
  yield* database.watchBooks();
});
