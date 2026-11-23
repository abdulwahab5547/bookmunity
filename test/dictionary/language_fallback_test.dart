import 'dart:io';

import 'package:bookmunity/core/sync/cloud_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bookmunity/features/dictionary/dictionary_preferences.dart';
import 'package:bookmunity/features/dictionary/dictionary_service.dart';
import 'package:bookmunity/features/dictionary/language_catalog.dart';
import 'package:bookmunity/features/dictionary/pack/kaikki_converter.dart';
import 'package:bookmunity/features/dictionary/pack/pack_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('language codes', () {
    test('normalise EPUB language tags', () {
      expect(normalizeLanguageCode('fr-FR'), 'fr');
      expect(normalizeLanguageCode('EN_gb'), 'en');
      expect(normalizeLanguageCode('fre'), 'fr');
      expect(normalizeLanguageCode('ger'), 'de');
      expect(normalizeLanguageCode('iw'), 'he');
      expect(normalizeLanguageCode('French'), 'fr');
      expect(normalizeLanguageCode(''), isNull);
      expect(normalizeLanguageCode(null), isNull);
      expect(normalizeLanguageCode('und-x-foo'), isNull);
    });

    test('every pack URL points at kaikki.org', () {
      for (final language in downloadableLanguages) {
        expect(language.downloadUri.host, 'kaikki.org');
        expect(language.downloadUri.path, endsWith('.jsonl.gz'));
        expect(language.code, hasLength(2));
      }
    });
  });

  group('resolveLookupLanguage', () {
    test('uses an installed pack for the book language', () {
      expect(
        resolveLookupLanguage(requested: 'fr-CA', installed: {'fr'}),
        const LookupLanguage('fr'),
      );
    });

    test('falls back to English and names the missing pack', () {
      expect(
        resolveLookupLanguage(requested: 'fr', installed: const {}),
        const LookupLanguage('en', missing: 'fr'),
      );
    });

    test('falls back to English silently for languages without packs', () {
      expect(
        resolveLookupLanguage(requested: 'ja', installed: const {}),
        const LookupLanguage('en'),
      );
      expect(
        resolveLookupLanguage(requested: null, installed: {'fr'}),
        const LookupLanguage('en'),
      );
      expect(
        resolveLookupLanguage(requested: 'en-US', installed: {'fr'}),
        const LookupLanguage('en'),
      );
    });
  });

  group('service fallback', () {
    late PackStore store;
    late DictionaryService service;

    setUpAll(() async {
      store = temporaryStore()..directory.createSync(recursive: true);
      await convertKaikkiGzip(
        Stream.value(gzippedFrenchFixture()),
        store.packFile('fr').path,
        language: 'fr',
        languageName: 'French',
        version: 'test',
      );
      service = DictionaryService(store);
    });
    tearDownAll(() => deleteStore(store));

    test('English answers and offers the missing pack', () async {
      store.close();
      final saved = store
          .packFile('fr')
          .renameSync('${store.directory.path}/x');
      addTearDown(() => File(saved.path).renameSync(store.packFile('fr').path));
      final result = await service.lookup(
        'running',
        language: resolveLookupLanguage(
          requested: 'fr',
          installed: store.installed().keys.toSet(),
        ),
      );
      expect(result, isA<DictionaryFound>());
      expect(result.source.language, 'en');
      expect(result.missingLanguage, 'fr');
    });

    test('the installed pack answers in its language', () async {
      final result = await service.lookup(
        'yeux',
        language: const LookupLanguage('fr'),
      );
      expect(result.source.language, 'fr');
      expect(result.source.attribution, contains('kaikki.org'));
      expect(result.missingLanguage, isNull);
      expect((result as DictionaryFound).entry.word, 'œil');
    });

    test('English words in a French book still resolve', () async {
      final result = await service.lookup(
        'mice',
        language: const LookupLanguage('fr'),
      );
      expect(result.source, DictionarySource.wordnet);
      expect((result as DictionaryFound).entry.word, 'mouse');
    });

    test('unknown words are not found, without an error state', () async {
      final result = await service.lookup(
        'qzxqzx',
        language: const LookupLanguage('fr'),
      );
      expect(result, isA<DictionaryNotFound>());
      expect(result.source.language, 'fr');
    });
  });

  group('preferences', () {
    test('are stored in the synced settings under dictionary. keys', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(cloudSettingsProvider.notifier).load();
      final controller = container.read(
        dictionaryPreferencesControllerProvider,
      );

      controller.addLanguage('fr');
      controller.addLanguage('de');
      controller.setLookupLanguage('fr');
      expect(
        container.read(dictionaryPreferencesProvider),
        const DictionaryPreferences(
          languages: {'de', 'fr'},
          lookupLanguage: 'fr',
        ),
      );
      final settings = container.read(cloudSettingsProvider);
      expect(settings.get<List>('dictionary.languages'), ['de', 'fr']);
      expect(settings.get<String>('dictionary.lookupLanguage'), 'fr');

      controller.removeLanguage('fr');
      expect(
        container.read(dictionaryPreferencesProvider),
        const DictionaryPreferences(languages: {'de'}),
      );
    });

    test('round-trip through JSON', () {
      const preferences = DictionaryPreferences(
        languages: {'fr', 'de'},
        lookupLanguage: 'fr',
      );
      final json = preferences.toJson();
      expect(json, {
        'languages': ['de', 'fr'],
        'lookupLanguage': 'fr',
      });
      expect(DictionaryPreferences.fromJson(json), preferences);
    });

    test('ignore unknown or malformed values', () {
      final parsed = DictionaryPreferences.fromJson({
        'languages': ['fr', 'xx', 3, 'en'],
        'lookupLanguage': 'zz',
      });
      expect(parsed.languages, {'fr'});
      expect(parsed.lookupLanguage, isNull);
      expect(
        DictionaryPreferences.fromJson(const {}),
        const DictionaryPreferences(),
      );
    });
  });
}
