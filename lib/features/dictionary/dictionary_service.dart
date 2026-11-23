import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/db/app_database.dart';
import 'dictionary_models.dart';
import 'language_catalog.dart';
import 'lookup/offline_dictionary.dart';
import 'pack/dictionary_pack.dart';
import 'pack/pack_store.dart';

export 'dictionary_models.dart';

/// Which dictionary a lookup uses.
class LookupLanguage {
  const LookupLanguage(this.code, {this.missing});

  /// The pack to search ('en' for the bundled one).
  final String code;

  /// The wanted language when its pack is not installed and English is
  /// used instead. Only set for languages that can be downloaded.
  final String? missing;

  @override
  bool operator ==(Object other) =>
      other is LookupLanguage && other.code == code && other.missing == missing;

  @override
  int get hashCode => Object.hash(code, missing);

  @override
  String toString() => 'LookupLanguage($code, missing: $missing)';
}

/// Picks the dictionary for a lookup. [requested] is the reader's choice,
/// or else the passage's or book's language. English is the fallback.
LookupLanguage resolveLookupLanguage({
  required String? requested,
  required Set<String> installed,
}) {
  final code = normalizeLanguageCode(requested);
  if (code == null || code == 'en') return const LookupLanguage('en');
  if (installed.contains(code)) return LookupLanguage(code);
  final downloadable = downloadableLanguages.any((l) => l.code == code);
  return LookupLanguage('en', missing: downloadable ? code : null);
}

/// Offline dictionary lookups: the bundled English WordNet plus any
/// downloaded language packs. Never waits for the network.
class DictionaryService {
  DictionaryService(this._store);

  final PackStore _store;

  Future<DictionaryResult> lookup(
    String word, {
    LookupLanguage language = const LookupLanguage('en'),
  }) async {
    final english = await _store.english();
    if (language.code != 'en') {
      final pack = _store.pack(language.code);
      if (pack != null) {
        final source = DictionarySource.wiktionary(
          language.code,
          languageByCode(language.code)?.name ?? language.code,
        );
        final entries = OfflineDictionary(pack, english: false).lookup(word);
        if (entries.isNotEmpty) {
          return DictionaryFound(query: word, source: source, entries: entries);
        }
        // Books quote other languages; English often knows the word.
        final fallback = OfflineDictionary(english, english: true).lookup(word);
        if (fallback.isNotEmpty) {
          return DictionaryFound(
            query: word,
            source: DictionarySource.wordnet,
            entries: fallback,
          );
        }
        return DictionaryNotFound(query: word, source: source);
      }
    }
    final missing = language.code == 'en'
        ? language.missing
        : normalizeLanguageCode(language.code);
    final entries = OfflineDictionary(english, english: true).lookup(word);
    return entries.isEmpty
        ? DictionaryNotFound(
            query: word,
            source: DictionarySource.wordnet,
            missingLanguage: missing,
          )
        : DictionaryFound(
            query: word,
            source: DictionarySource.wordnet,
            entries: entries,
            missingLanguage: missing,
          );
  }

  /// Exposed for tests and tools.
  static String normalize(String word) => PackSchema.key(word);
}

/// Optional online extra: pronunciation from dictionaryapi.dev, cached in
/// the app database. Failures are silent and nothing waits for it.
class OnlinePhonetics {
  OnlinePhonetics(this._database, {http.Client? client})
    : _client = client ?? http.Client();

  final AppDatabase _database;
  final http.Client _client;

  static Uri _uri(String word) => Uri.https(
    'api.dictionaryapi.dev',
    '/api/v2/entries/en/${Uri.encodeComponent(word)}',
  );

  /// The phonetic spelling of an English headword, or null.
  Future<String?> phonetic(String word) async {
    final key = PackSchema.key(word);
    if (key.isEmpty || key.contains(' ')) return null;
    final cached = await _database.cachedDefinition(key);
    if (cached != null) return DictionaryEntry.parse(cached)?.phonetic;
    try {
      final response = await _client
          .get(_uri(key))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final body = utf8.decode(response.bodyBytes);
      final entry = DictionaryEntry.parse(body);
      if (entry == null) return null;
      await _database.cacheDefinition(key, body);
      return entry.phonetic;
    } catch (_) {
      return null;
    }
  }
}
