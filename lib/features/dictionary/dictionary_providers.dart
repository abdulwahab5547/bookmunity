import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../providers/app_providers.dart';
import 'dictionary_preferences.dart';
import 'dictionary_service.dart';
import 'language_catalog.dart';
import 'pack/pack_installer.dart';
import 'pack/pack_store.dart';

final packStoreProvider = FutureProvider<PackStore>((ref) async {
  final support = await getApplicationSupportDirectory();
  final store = PackStore(
    Directory('${support.path}/dictionaries'),
    loadEnglishAsset: () async =>
        (await rootBundle.load(PackStore.englishAsset)).buffer.asUint8List(),
  );
  ref.onDispose(store.close);
  return store;
});

final dictionaryServiceProvider = FutureProvider<DictionaryService>((
  ref,
) async {
  return DictionaryService(await ref.watch(packStoreProvider.future));
});

final onlinePhoneticsProvider = FutureProvider<OnlinePhonetics>((ref) async {
  return OnlinePhonetics(await ref.watch(databaseProvider.future));
});

/// Pronunciation for an English headword when online; null otherwise.
final phoneticProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  word,
) async {
  final online = await ref.watch(onlinePhoneticsProvider.future);
  return online.phonetic(word);
});

class PackTask {
  const PackTask({
    this.phase = PackInstallPhase.downloading,
    this.received = 0,
    this.total,
    this.error,
  });

  final PackInstallPhase phase;
  final int received;
  final int? total;

  /// Set when the last attempt failed.
  final String? error;

  bool get running => error == null;

  double? get fraction =>
      total == null || total == 0 ? null : (received / total!).clamp(0, 1);
}

class DictionaryPacksState {
  const DictionaryPacksState({
    this.installed = const {},
    this.tasks = const {},
    this.revision = 0,
  });

  /// Installed language code -> size on disk in bytes.
  final Map<String, int> installed;
  final Map<String, PackTask> tasks;

  /// Bumped whenever a pack is installed or removed.
  final int revision;

  DictionaryPacksState copyWith({
    Map<String, int>? installed,
    Map<String, PackTask>? tasks,
    int? revision,
  }) => DictionaryPacksState(
    installed: installed ?? this.installed,
    tasks: tasks ?? this.tasks,
    revision: revision ?? this.revision,
  );
}

/// Installs and removes language packs and tracks downloads in progress.
class DictionaryPacksController extends StateNotifier<DictionaryPacksState> {
  DictionaryPacksController(this._ref) : super(const DictionaryPacksState()) {
    unawaited(refresh());
  }

  final Ref _ref;
  final Map<String, PackInstallJob> _jobs = {};

  Future<PackStore> get _store => _ref.read(packStoreProvider.future);

  Future<void> refresh() async {
    final store = await _store;
    if (!mounted) return;
    state = state.copyWith(
      installed: store.installed(),
      revision: state.revision + 1,
    );
  }

  Future<void> download(DictionaryLanguage language) async {
    if (_jobs.containsKey(language.code)) return;
    final store = await _store;
    store.directory.createSync(recursive: true);
    _setTask(language.code, const PackTask());
    final job = await PackInstallJob.start(
      uri: language.downloadUri,
      partPath: store.partFile(language.code).path,
      finalPath: store.packFile(language.code).path,
      language: language.code,
      languageName: language.name,
    );
    _jobs[language.code] = job;
    final subscription = job.progress.listen((progress) {
      if (!mounted) return;
      _setTask(
        language.code,
        PackTask(
          phase: progress.phase,
          received: progress.received,
          total: progress.total ?? language.downloadBytes,
        ),
      );
    });
    try {
      await job.done;
      _ref
          .read(dictionaryPreferencesControllerProvider)
          .addLanguage(language.code);
      _removeTask(language.code);
    } on PackInstallCancelled {
      _removeTask(language.code);
    } catch (error) {
      _setTask(language.code, PackTask(error: '$error'));
    } finally {
      await subscription.cancel();
      _jobs.remove(language.code);
      await refresh();
    }
  }

  Future<void> cancel(String code) async {
    final job = _jobs[code];
    if (job != null) {
      await job.cancel();
    } else {
      _removeTask(code);
    }
  }

  Future<void> delete(String code) async {
    await cancel(code);
    final store = await _store;
    await store.delete(code);
    _ref.read(dictionaryPreferencesControllerProvider).removeLanguage(code);
    await refresh();
  }

  void _setTask(String code, PackTask task) {
    if (!mounted) return;
    state = state.copyWith(tasks: {...state.tasks, code: task});
  }

  void _removeTask(String code) {
    if (!mounted || !state.tasks.containsKey(code)) return;
    state = state.copyWith(tasks: {...state.tasks}..remove(code));
  }

  @override
  void dispose() {
    for (final job in _jobs.values) {
      unawaited(job.cancel());
    }
    super.dispose();
  }
}

final dictionaryPacksProvider =
    StateNotifierProvider<DictionaryPacksController, DictionaryPacksState>(
      DictionaryPacksController.new,
    );

/// A word to define and where it was read. [language] is the passage's or
/// book's language tag (EPUB `dc:language`), if known.
typedef DictionaryQuery = ({String word, int? bookId, String? language});

/// The language picked in the definition sheet, per open book, for this
/// session. Null follows the reader's setting or the book.
final lookupOverrideProvider = StateProvider.family<String?, int>(
  (ref, bookId) => null,
);

/// The language a query will be looked up in.
final lookupLanguageProvider = FutureProvider.autoDispose
    .family<LookupLanguage, DictionaryQuery>((ref, query) async {
      final preferences = ref.watch(dictionaryPreferencesProvider);
      final bookId = query.bookId;
      final override = bookId == null
          ? null
          : ref.watch(lookupOverrideProvider(bookId));
      ref.watch(dictionaryPacksProvider.select((state) => state.revision));
      final store = await ref.watch(packStoreProvider.future);
      return resolveLookupLanguage(
        requested: override ?? preferences.lookupLanguage ?? query.language,
        installed: store.installed().keys.toSet(),
      );
    });

final definitionProvider = FutureProvider.autoDispose
    .family<DictionaryResult, DictionaryQuery>((ref, query) async {
      final language = await ref.watch(lookupLanguageProvider(query).future);
      final service = await ref.watch(dictionaryServiceProvider.future);
      return service.lookup(query.word, language: language);
    });
