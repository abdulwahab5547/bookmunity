import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'dictionary_pack.dart';

/// Where dictionary packs live on the device: the bundled English pack,
/// unpacked from its asset on first use, and each downloaded language as
/// `<code>.db`.
class PackStore {
  PackStore(this.directory, {required this.loadEnglishAsset});

  final Directory directory;

  /// Reads the gzipped English pack (assets/dictionary/en_wordnet.db.gz).
  final Future<List<int>> Function() loadEnglishAsset;

  /// Bump with the asset so updated builds replace the unpacked copy.
  static const englishVersion = 'wordnet-3.1-1';
  static const englishAsset = 'assets/dictionary/en_wordnet.db.gz';

  final Map<String, DictionaryPack> _open = {};
  Future<DictionaryPack>? _english;

  File packFile(String code) => File('${directory.path}/$code.db');
  File partFile(String code) => File('${directory.path}/$code.db.part');
  File get englishFile => File('${directory.path}/en-$englishVersion.db');

  /// The bundled English pack. Unpacks it once (about a second, off the UI
  /// isolate); never touches the network.
  Future<DictionaryPack> english() =>
      _english ??= _openEnglish().catchError((Object error) {
        _english = null;
        throw error;
      });

  Future<DictionaryPack> _openEnglish() async {
    final file = englishFile;
    if (!file.existsSync()) {
      directory.createSync(recursive: true);
      final compressed = await loadEnglishAsset();
      final temp = '${file.path}.part';
      await Isolate.run(() {
        File(temp).writeAsBytesSync(gzip.decode(compressed), flush: true);
      });
      File(temp).renameSync(file.path);
      // Remove copies unpacked by older builds.
      for (final old in directory.listSync().whereType<File>()) {
        final name = old.uri.pathSegments.last;
        if (name.startsWith('en-') && old.path != file.path) old.deleteSync();
      }
    }
    return DictionaryPack.open(file.path);
  }

  bool isInstalled(String code) => packFile(code).existsSync();

  /// Installed language codes with their size on disk.
  Map<String, int> installed() {
    if (!directory.existsSync()) return const {};
    final result = <String, int>{};
    for (final file in directory.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (!name.endsWith('.db') || name.startsWith('en-')) continue;
      result[name.substring(0, name.length - 3)] = file.lengthSync();
    }
    return result;
  }

  /// An installed pack, or null.
  DictionaryPack? pack(String code) {
    final cached = _open[code];
    if (cached != null) return cached;
    final file = packFile(code);
    if (!file.existsSync()) return null;
    try {
      return _open[code] = DictionaryPack.open(file.path);
    } on Object {
      return null;
    }
  }

  Future<void> delete(String code) async {
    _open.remove(code)?.close();
    for (final file in [packFile(code), partFile(code)]) {
      if (file.existsSync()) await file.delete();
    }
  }

  void close() {
    for (final pack in _open.values) {
      pack.close();
    }
    _open.clear();
  }
}
