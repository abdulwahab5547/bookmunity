import 'dart:convert';

/// One numbered definition.
class DictionarySense {
  const DictionarySense({
    required this.definition,
    this.examples = const [],
    this.synonyms = const [],
  });

  final String definition;
  final List<String> examples;
  final List<String> synonyms;

  String? get example => examples.isEmpty ? null : examples.first;
}

class DictionaryMeaning {
  const DictionaryMeaning({required this.partOfSpeech, required this.senses});

  final String partOfSpeech;
  final List<DictionarySense> senses;
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.meanings,
    this.phonetic,
    this.note,
  });

  final String word;
  final String? phonetic;
  final List<DictionaryMeaning> meanings;

  /// How the looked-up word relates to this headword, e.g. "plural of
  /// mouse" or "first-person plural present indicative of manger".
  final String? note;

  /// The first definition, for the compact Kindle-style preview.
  String? get shortDefinition =>
      meanings.isEmpty || meanings.first.senses.isEmpty
      ? null
      : meanings.first.senses.first.definition;

  DictionaryEntry withPhonetic(String? value) => DictionaryEntry(
    word: word,
    meanings: meanings,
    phonetic: value ?? phonetic,
    note: note,
  );

  /// Parses the dictionaryapi.dev response (a list of entries for one word).
  static DictionaryEntry? parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List || decoded.isEmpty) return null;
    final meanings = <DictionaryMeaning>[];
    String? word;
    String? phonetic;
    for (final rawEntry in decoded) {
      if (rawEntry is! Map) continue;
      word ??= rawEntry['word'] as String?;
      phonetic ??= _phonetic(rawEntry);
      for (final rawMeaning in rawEntry['meanings'] as List? ?? const []) {
        if (rawMeaning is! Map) continue;
        final senses = <DictionarySense>[
          for (final rawSense in rawMeaning['definitions'] as List? ?? const [])
            if (rawSense is Map &&
                (rawSense['definition'] as String?)?.trim().isNotEmpty == true)
              DictionarySense(
                definition: (rawSense['definition'] as String).trim(),
                examples: [
                  if ((rawSense['example'] as String?)?.trim().isNotEmpty ==
                      true)
                    (rawSense['example'] as String).trim(),
                ],
              ),
        ];
        if (senses.isEmpty) continue;
        final partOfSpeech = (rawMeaning['partOfSpeech'] as String?) ?? '';
        final existing = meanings.indexWhere(
          (meaning) => meaning.partOfSpeech == partOfSpeech,
        );
        if (existing >= 0) {
          meanings[existing] = DictionaryMeaning(
            partOfSpeech: partOfSpeech,
            senses: [...meanings[existing].senses, ...senses],
          );
        } else {
          meanings.add(
            DictionaryMeaning(partOfSpeech: partOfSpeech, senses: senses),
          );
        }
      }
    }
    if (word == null || meanings.isEmpty) return null;
    return DictionaryEntry(word: word, phonetic: phonetic, meanings: meanings);
  }

  static String? _phonetic(Map<dynamic, dynamic> entry) {
    final direct = (entry['phonetic'] as String?)?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    for (final item in entry['phonetics'] as List? ?? const []) {
      final text = item is Map ? (item['text'] as String?)?.trim() : null;
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }
}

/// Where an answer came from, with the line the licence asks us to show.
class DictionarySource {
  const DictionarySource({
    required this.language,
    required this.name,
    required this.attribution,
  });

  final String language;
  final String name;
  final String attribution;

  static const wordnet = DictionarySource(
    language: 'en',
    name: 'WordNet 3.1',
    attribution:
        'Definitions from WordNet 3.1, © 2011 Princeton University. '
        'Used under the WordNet licence.',
  );

  static DictionarySource wiktionary(String language, String languageName) =>
      DictionarySource(
        language: language,
        name: 'Wiktionary ($languageName)',
        attribution:
            'Definitions from English Wiktionary via kaikki.org, '
            'CC BY-SA 4.0 and GFDL.',
      );
}

sealed class DictionaryResult {
  const DictionaryResult({
    required this.query,
    required this.source,
    this.missingLanguage,
  });

  final String query;

  /// The dictionary that was searched.
  final DictionarySource source;

  /// The language the lookup wanted but could not use because its pack is
  /// not installed. English answered instead.
  final String? missingLanguage;
}

class DictionaryFound extends DictionaryResult {
  const DictionaryFound({
    required super.query,
    required super.source,
    required this.entries,
    super.missingLanguage,
  });

  /// Best match first: the word itself, or the base form it inflects.
  /// Never empty.
  final List<DictionaryEntry> entries;

  DictionaryEntry get entry => entries.first;
}

class DictionaryNotFound extends DictionaryResult {
  const DictionaryNotFound({
    required super.query,
    required super.source,
    super.missingLanguage,
  });
}
