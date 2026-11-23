import '../dictionary_models.dart';
import '../pack/dictionary_pack.dart';
import 'english_morphology.dart';

/// Looks words up in one pack, resolving inflected forms to their
/// headwords. Synchronous: every query hits a primary-key index.
class OfflineDictionary {
  OfflineDictionary(this.pack, {required this.english});

  final DictionaryPack pack;

  /// English packs also apply WordNet's morphy suffix rules.
  final bool english;

  /// Entries for [text], best match first; empty when nothing matches.
  List<DictionaryEntry> lookup(String text) {
    final key = PackSchema.key(text);
    if (key.isEmpty) return const [];
    for (final candidate in _variants(key)) {
      final entries = _lookupKey(candidate, original: key);
      if (entries.isNotEmpty) return entries;
    }
    return const [];
  }

  /// The key itself, then spellings without elisions and possessives:
  /// "l'homme" -> "homme", "dell'arte" -> "arte", "alice's" -> "alice".
  static List<String> _variants(String key) {
    final result = <String>[key];
    void add(String value) {
      final cleaned = PackSchema.key(value);
      if (cleaned.isNotEmpty && !result.contains(cleaned)) result.add(cleaned);
    }

    if (!key.contains(' ') && key.contains("'")) {
      if (key.endsWith("'s")) add(key.substring(0, key.length - 2));
      if (key.endsWith("s'")) add(key.substring(0, key.length - 1));
      add(key.substring(key.lastIndexOf("'") + 1));
      add(key.substring(0, key.indexOf("'")));
    }
    if (key.contains('-')) add(key.replaceAll('-', ' '));
    return result;
  }

  List<DictionaryEntry> _lookupKey(String key, {required String original}) {
    final sections = <String, _Section>{};

    void addRows(List<PackEntryRow> rows, {String? note, bool direct = false}) {
      for (final row in rows) {
        final section = sections.putIfAbsent(
          row.key,
          () => _Section(word: row.word, direct: direct, note: note),
        );
        section.rows.add(row);
        section.rank += row.rank;
      }
    }

    addRows(pack.entries(key), direct: true);

    // Inflections listed in the pack (exception lists, Wiktionary form-of).
    for (final form in pack.forms(key)) {
      if (form.lemma == key) continue;
      var rows = form.pos.isEmpty
          ? pack.entries(form.lemma)
          : pack.entries(form.lemma, pos: form.pos);
      if (rows.isEmpty && form.pos.isNotEmpty) rows = pack.entries(form.lemma);
      rows = rows.where((row) => !_already(sections, row)).toList();
      addRows(rows, note: form.note ?? _formNote(original, form.lemma));
    }

    if (english) {
      for (final (base, pos) in _englishBases(key)) {
        final rows = pack
            .entries(base, pos: pos)
            .where((row) => !_already(sections, row))
            .toList();
        addRows(rows, note: _formNote(original, base));
      }
    }

    final ordered = sections.values.toList();
    if (english) {
      // WordNet's tagged-sense counts say how common each reading is, so
      // "better" leads with good and "saw" with see.
      ordered.sort((a, b) {
        final byRank = b.rank.compareTo(a.rank);
        if (byRank != 0) return byRank;
        return (b.direct ? 1 : 0) - (a.direct ? 1 : 0);
      });
    }
    return [
      for (final section in ordered)
        if (_entry(section) case final entry when entry.meanings.isNotEmpty)
          entry,
    ];
  }

  static bool _already(Map<String, _Section> sections, PackEntryRow row) =>
      sections[row.key]?.rows.any(
        (existing) => existing.pos == row.pos && existing.senses == row.senses,
      ) ??
      false;

  static String _formNote(String original, String lemma) =>
      '“$original” is a form of $lemma';

  /// English base forms from exception lists and suffix rules, including
  /// phrases whose first or last word is inflected.
  List<(String, String)> _englishBases(String key) {
    List<String> baseForms(String word, String pos) => [
      for (final form in pack.forms(word))
        if (form.pos == pos) form.lemma,
      for (final (base, candidatePos) in EnglishMorphology.candidates(word))
        if (candidatePos == pos && pack.has(base, pos: pos)) base,
    ];

    final result = <(String, String)>[];
    if (key.contains(' ')) {
      for (final (phrase, pos) in EnglishMorphology.phraseCandidates(
        key,
        baseForms,
      )) {
        if (pack.has(phrase, pos: pos)) result.add((phrase, pos));
      }
      return result;
    }
    for (final (base, pos) in EnglishMorphology.candidates(key)) {
      if (pack.has(base, pos: pos)) result.add((base, pos));
    }
    return result;
  }

  DictionaryEntry _entry(_Section section) {
    final meanings = <DictionaryMeaning>[];
    final headword = section.word.toLowerCase();
    // Most common part of speech first (a stable sort keeps pack order for
    // packs without ranks).
    final indexed = section.rows.indexed.toList()
      ..sort((a, b) {
        final byRank = b.$2.rank.compareTo(a.$2.rank);
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    for (final (_, row) in indexed) {
      final senses = [
        for (final sense in pack.senses(row))
          DictionarySense(
            definition: sense.definition,
            examples: sense.examples,
            synonyms: [
              for (final word in sense.words)
                if (word.toLowerCase() != headword) word,
            ],
          ),
      ];
      if (senses.isEmpty) continue;
      final index = meanings.indexWhere((m) => m.partOfSpeech == row.pos);
      if (index >= 0) {
        meanings[index] = DictionaryMeaning(
          partOfSpeech: row.pos,
          senses: [...meanings[index].senses, ...senses],
        );
      } else {
        meanings.add(DictionaryMeaning(partOfSpeech: row.pos, senses: senses));
      }
    }
    return DictionaryEntry(
      word: section.word,
      meanings: meanings,
      note: section.direct ? null : section.note,
    );
  }
}

class _Section {
  _Section({required this.word, required this.direct, this.note});

  final String word;
  final bool direct;
  final String? note;
  final List<PackEntryRow> rows = [];
  int rank = 0;
}
