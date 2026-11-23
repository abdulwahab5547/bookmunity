// Looks words up in a dictionary pack with the app's lookup code.
//
//   dart run tools/dictionary/lookup.dart <pack.db> word [word ...]
//
// For the bundled English pack, unpack it first:
//   gunzip -c assets/dictionary/en_wordnet.db.gz > /tmp/en.db
import 'dart:io';

import 'package:bookmunity/features/dictionary/lookup/offline_dictionary.dart';
import 'package:bookmunity/features/dictionary/pack/dictionary_pack.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: lookup.dart <pack.db> word [word ...]');
    exit(64);
  }
  final pack = DictionaryPack.open(args.first);
  final dictionary = OfflineDictionary(pack, english: pack.language == 'en');
  for (final word in args.skip(1)) {
    final watch = Stopwatch()..start();
    final entries = dictionary.lookup(word);
    final elapsed = watch.elapsedMicroseconds / 1000;
    if (entries.isEmpty) {
      stdout.writeln('$word: (not found) [${elapsed}ms]');
      continue;
    }
    stdout.writeln('$word: [${elapsed}ms]');
    for (final entry in entries.take(3)) {
      final meaning = entry.meanings.first;
      stdout.writeln(
        '  ${entry.word}${entry.note == null ? '' : ' (${entry.note})'} — '
        '${meaning.partOfSpeech}: ${entry.shortDefinition}',
      );
    }
  }
  pack.close();
}
