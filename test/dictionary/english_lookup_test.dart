import 'package:bookmunity/features/dictionary/dictionary_service.dart';
import 'package:bookmunity/features/dictionary/lookup/english_morphology.dart';
import 'package:bookmunity/features/dictionary/lookup/offline_dictionary.dart';
import 'package:bookmunity/features/dictionary/pack/dictionary_pack.dart';
import 'package:bookmunity/features/dictionary/pack/pack_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('morphy rules', () {
    test('suggest base forms by part of speech', () {
      final running = EnglishMorphology.candidates('running');
      expect(running, contains(('run', 'verb')));
      expect(
        EnglishMorphology.candidates('studies'),
        contains(('study', 'noun')),
      );
      expect(EnglishMorphology.candidates('boxes'), contains(('box', 'noun')));
      expect(
        EnglishMorphology.candidates('bigger'),
        contains(('big', 'adjective')),
      );
      expect(
        EnglishMorphology.candidates('making'),
        contains(('make', 'verb')),
      );
      // Doubling is not undone for vowels or short stems.
      expect(
        EnglishMorphology.candidates('seeing'),
        isNot(contains(('se', 'verb'))),
      );
    });

    test('normalises keys like the build script', () {
      expect(PackSchema.key('  Running, '), 'running');
      expect(PackSchema.key('Alice’s'), "alice's");
      expect(PackSchema.key('ice_cream'), 'ice cream');
      expect(PackSchema.key('«Look   up»'), 'look up');
      expect(PackSchema.key('молоко́'), 'молоко');
    });
  });

  group('bundled WordNet, offline', () {
    late PackStore store;
    late OfflineDictionary dictionary;

    setUpAll(() async {
      store = temporaryStore();
      dictionary = OfflineDictionary(await store.english(), english: true);
    });
    tearDownAll(() => deleteStore(store));

    List<String> words(String query) =>
        dictionary.lookup(query).map((entry) => entry.word).toList();

    test('resolves inflected forms to their headwords', () {
      expect(words('running'), contains('run'));
      expect(words('running').first, 'run');
      expect(words('mice'), ['mouse']);
      expect(words('better').first, 'good');
      expect(words('better'), containsAll(['good', 'well', 'better']));
      expect(words('studies').first, 'study');
      expect(words('went'), ['go']);
      expect(words('geese'), ['goose']);
      expect(words('stopped'), contains('stop'));
      expect(words('Children'), ['child']);
    });

    test('explains how the word relates to the headword', () {
      final mouse = dictionary.lookup('mice').single;
      expect(mouse.note, contains('form of mouse'));
      expect(mouse.meanings.first.partOfSpeech, 'noun');
      expect(mouse.shortDefinition, contains('rodent'));
    });

    test('finds phrases and multi-word entries', () {
      expect(words('look up'), ['look up']);
      expect(words('looking up'), contains('look up'));
      expect(words('ice creams'), contains('ice cream'));
      expect(words('New York'), ['New York']);
      expect(words('well-known'), contains('well-known'));
    });

    test('handles punctuation, possessives and case', () {
      expect(words('“Dog’s”'), contains('dog'));
      expect(words('HOUSES,'), contains('house'));
    });

    test('includes examples and synonyms', () {
      final good = dictionary.lookup('good').first;
      final senses = good.meanings.expand((m) => m.senses).toList();
      expect(senses.any((sense) => sense.examples.isNotEmpty), isTrue);
      expect(senses.any((sense) => sense.synonyms.isNotEmpty), isTrue);
      expect(senses.every((sense) => !sense.synonyms.contains('good')), isTrue);
    });

    test('returns nothing for gibberish', () {
      expect(dictionary.lookup('qzxqzx'), isEmpty);
      expect(dictionary.lookup('...'), isEmpty);
    });

    test('service answers from WordNet with its attribution', () async {
      final service = DictionaryService(store);
      final result = await service.lookup('mice');
      expect(result, isA<DictionaryFound>());
      expect(result.source, DictionarySource.wordnet);
      expect(result.source.attribution, contains('WordNet'));
      expect((result as DictionaryFound).entry.word, 'mouse');
    });

    test('unpacks the asset once', () async {
      expect(store.englishFile.existsSync(), isTrue);
      final again = await store.english();
      expect(again.language, 'en');
      expect(again.meta['version'], PackStore.englishVersion);
    });
  });
}
