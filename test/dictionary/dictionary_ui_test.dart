import 'package:bookmunity/design/brutal_theme.dart';
import 'package:bookmunity/features/dictionary/dictionaries_screen.dart';
import 'package:bookmunity/features/dictionary/dictionary_providers.dart';
import 'package:bookmunity/features/dictionary/dictionary_service.dart';
import 'package:bookmunity/features/dictionary/dictionary_view.dart';
import 'package:bookmunity/features/dictionary/pack/pack_installer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePacks extends DictionaryPacksController {
  _FakePacks(super.ref, this._initial);

  final DictionaryPacksState _initial;

  @override
  Future<void> refresh() async => state = _initial;
}

const _query = (word: 'mangeons', bookId: 1, language: 'fr');

const _found = DictionaryFound(
  query: 'mangeons',
  source: DictionarySource.wordnet,
  missingLanguage: 'fr',
  entries: [
    DictionaryEntry(
      word: 'mangeons',
      meanings: [
        DictionaryMeaning(
          partOfSpeech: 'noun',
          senses: [
            DictionarySense(
              definition: 'A made-up definition long enough to wrap.',
              examples: ['An example.'],
              synonyms: ['other'],
            ),
          ],
        ),
      ],
    ),
  ],
);

Widget _app(Widget child, {required bool dark, DictionaryPacksState? packs}) {
  return ProviderScope(
    overrides: [
      dictionaryPacksProvider.overrideWith(
        (ref) => _FakePacks(
          ref,
          packs ??
              const DictionaryPacksState(
                installed: {'de': 41000000},
                tasks: {
                  'fr': PackTask(received: 20000000, total: 59206544),
                  'es': PackTask(phase: PackInstallPhase.installing),
                  'it': PackTask(error: 'No connection.'),
                },
              ),
        ),
      ),
      definitionProvider.overrideWith((ref, query) async => _found),
      lookupLanguageProvider.overrideWith(
        (ref, query) async => const LookupLanguage('en', missing: 'fr'),
      ),
      phoneticProvider.overrideWith((ref, word) async => null),
    ],
    child: MaterialApp(
      theme: brutalTheme(dark: dark),
      home: child,
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('Dictionaries screen lists packs ($mode)', (tester) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const DictionariesScreen(), dark: dark));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Built in'), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);
      expect(find.textContaining('German'), findsWidgets);
      expect(find.textContaining('Downloading 34%'), findsOneWidget);
      expect(find.textContaining('Installing'), findsOneWidget);
      expect(find.text('Cancel'), findsNWidgets(2));
      expect(find.text('No connection.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('MB download'), findsWidgets);
    });

    testWidgets('definition sheet offers the missing pack ($mode)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: DictionaryDetail(
              query: _query,
              controller: ScrollController(),
            ),
          ),
          dark: dark,
          packs: const DictionaryPacksState(),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('This book is in French'), findsOneWidget);
      expect(find.textContaining('Download French · 56 MB'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.textContaining('WordNet 3.1'), findsOneWidget);
      expect(find.text('Also: other'), findsOneWidget);
    });
  }
}
