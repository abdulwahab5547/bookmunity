/// WordNet's morphy rules: the suffix substitutions it tries for each part
/// of speech before checking the result against the dictionary. Irregular
/// forms (mice, went, better) come from the exception lists in the pack's
/// `forms` table instead.
abstract final class EnglishMorphology {
  static const _rules = <String, List<(String, String)>>{
    'noun': [
      ('s', ''),
      ('ses', 's'),
      ('xes', 'x'),
      ('zes', 'z'),
      ('ches', 'ch'),
      ('shes', 'sh'),
      ('men', 'man'),
      ('ies', 'y'),
    ],
    'verb': [
      ('s', ''),
      ('ies', 'y'),
      ('es', 'e'),
      ('es', ''),
      ('ed', 'e'),
      ('ed', ''),
      ('ing', 'e'),
      ('ing', ''),
    ],
    'adjective': [('er', ''), ('est', ''), ('er', 'e'), ('est', 'e')],
  };

  /// Suffixes after which a doubled final consonant is undone, as in
  /// stopped, running, bigger (WordNet lists only some of these).
  static const _doubling = {'ed', 'ing', 'er', 'est'};

  /// Candidate base forms of a single word, by part of speech. Callers keep
  /// only those that exist in the dictionary.
  static List<(String, String)> candidates(String word) {
    final result = <(String, String)>[];
    void add(String base, String pos) {
      if (base.length < 2 || base == word) return;
      final candidate = (base, pos);
      if (!result.contains(candidate)) result.add(candidate);
    }

    for (final MapEntry(key: pos, value: rules) in _rules.entries) {
      for (final (suffix, replacement) in rules) {
        if (!word.endsWith(suffix) || word.length <= suffix.length) continue;
        final stem = word.substring(0, word.length - suffix.length);
        add('$stem$replacement', pos);
        if (replacement.isEmpty &&
            _doubling.contains(suffix) &&
            stem.length > 2 &&
            stem[stem.length - 1] == stem[stem.length - 2] &&
            !'aeiou'.contains(stem[stem.length - 1])) {
          add(stem.substring(0, stem.length - 1), pos);
        }
      }
    }
    return result;
  }

  /// Variants of a phrase with its first or last word reduced, the way
  /// morphy handles collocations: "looking up" -> "look up",
  /// "ice creams" -> "ice cream".
  static List<(String, String)> phraseCandidates(
    String phrase,
    List<String> Function(String word, String pos) baseForms,
  ) {
    final words = phrase.split(' ');
    if (words.length < 2) return const [];
    final result = <(String, String)>[];
    final first = words.first;
    final rest = words.skip(1).join(' ');
    for (final base in baseForms(first, 'verb')) {
      result.add(('$base $rest', 'verb'));
    }
    final last = words.last;
    final head = words.take(words.length - 1).join(' ');
    for (final base in baseForms(last, 'noun')) {
      result.add(('$head $base', 'noun'));
    }
    return result;
  }
}
