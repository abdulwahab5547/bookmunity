import 'dart:io';

import 'package:bookmunity/features/dictionary/lookup/offline_dictionary.dart';
import 'package:bookmunity/features/dictionary/pack/dictionary_pack.dart';
import 'package:bookmunity/features/dictionary/pack/kaikki_converter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Directory directory;
  late DictionaryPack pack;
  late KaikkiConverter converter;
  late OfflineDictionary dictionary;

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('kaikki_test_');
    final path = '${directory.path}/fr.db';
    converter = await convertKaikkiGzip(
      Stream.value(gzippedFrenchFixture()),
      path,
      language: 'fr',
      languageName: 'French',
      version: 'test',
    );
    pack = DictionaryPack.open(path);
    dictionary = OfflineDictionary(pack, english: false);
  });

  tearDownAll(() {
    pack.close();
    directory.deleteSync(recursive: true);
  });

  test('keeps headwords and turns form-of senses into forms', () {
    // Skipped: the romanization, the gloss-less entry, the bad line, and
    // the form-of-only entries (stored as forms instead).
    expect(converter.entries, 7);
    expect(converter.forms, 4);
    expect(converter.lines, 13);
    expect(pack.meta['language'], 'fr');
    expect(pack.meta['attribution'], contains('Wiktionary'));
    expect(pack.has('ignored'), isFalse);
    expect(pack.has('sans gloss'), isFalse);
  });

  test('parses glosses, examples and parts of speech', () {
    final beau = dictionary.lookup('beau').single;
    expect(beau.meanings.single.partOfSpeech, 'adjective');
    final senses = beau.meanings.single.senses;
    expect(senses.map((s) => s.definition), [
      'handsome, fine, attractive',
      'fair (weather)',
    ]);
    expect(senses[1].examples, ['Il fait beau. — It is nice out.']);
    expect(
      dictionary.lookup('Paris').single.meanings.single.partOfSpeech,
      'proper noun',
    );
  });

  test('merges homographs by headword', () {
    final manger = dictionary.lookup('manger').single;
    expect(manger.meanings.map((m) => m.partOfSpeech), ['verb', 'noun']);
    expect(manger.note, isNull);
  });

  test('resolves inflected forms with the Wiktionary note', () {
    final entries = dictionary.lookup('Mangeons');
    expect(entries.single.word, 'manger');
    expect(entries.single.note, contains('first-person plural'));
    expect(dictionary.lookup('yeux').single.word, 'œil');
    expect(dictionary.lookup('belles').single.word, 'beau');
  });

  test('handles elision and multi-word entries', () {
    expect(dictionary.lookup("l'homme").single.word, 'homme');
    expect(dictionary.lookup('l’homme').single.word, 'homme');
    expect(dictionary.lookup('pomme de terre').single.word, 'pomme de terre');
  });
}
