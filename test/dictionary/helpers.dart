import 'dart:io';

import 'package:bookmunity/features/dictionary/pack/pack_store.dart';

/// The fixture as kaikki.org serves it: gzipped JSON Lines.
List<int> gzippedFrenchFixture() => gzip.encode(
  File('test/dictionary/fixtures/kaikki_fr_sample.jsonl').readAsBytesSync(),
);

/// A store in a fresh temporary directory that unpacks the real bundled
/// English dictionary (assets/dictionary/en_wordnet.db.gz).
PackStore temporaryStore() {
  final directory = Directory.systemTemp.createTempSync('dictionary_test_');
  return PackStore(
    Directory('${directory.path}/dictionaries'),
    loadEnglishAsset: () async =>
        File(PackStore.englishAsset).readAsBytesSync(),
  );
}

void deleteStore(PackStore store) {
  store.close();
  final parent = store.directory.parent;
  if (parent.existsSync()) parent.deleteSync(recursive: true);
}
