import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'dictionary_pack.dart';

/// Converts kaikki.org JSON Lines (one Wiktionary entry per line, see
/// https://kaikki.org/dictionary/rawdata.html) into a dictionary pack.
///
/// Only what the reader shows is kept: headword, part of speech, glosses
/// and one or two examples. Form-of and alternative-spelling senses become
/// rows in `forms`, which is how "mangeons" finds "manger".
class KaikkiConverter {
  KaikkiConverter(
    this._db, {
    required this.language,
    required this.languageName,
  });

  final Database _db;
  final String language;
  final String languageName;

  late final PreparedStatement _insertEntry;
  late final PreparedStatement _insertForm;
  int _seq = 0;
  int forms = 0;
  int lines = 0;

  int get entries => _seq;

  static const _partsOfSpeech = {
    'adj': 'adjective',
    'adv': 'adverb',
    'name': 'proper noun',
    'pron': 'pronoun',
    'prep': 'preposition',
    'postp': 'postposition',
    'conj': 'conjunction',
    'intj': 'interjection',
    'det': 'determiner',
    'num': 'numeral',
    'article': 'article',
    'particle': 'particle',
    'phrase': 'phrase',
    'prep_phrase': 'phrase',
    'contraction': 'contraction',
    'abbrev': 'abbreviation',
  };

  static const _skippedPartsOfSpeech = {'romanization', 'character', 'symbol'};

  void begin() {
    _db.execute('PRAGMA journal_mode = OFF');
    _db.execute('PRAGMA synchronous = OFF');
    PackSchema.create(_db);
    _insertEntry = _db.prepare(
      'INSERT INTO entries(key, seq, word, pos, rank, senses) '
      'VALUES(?, ?, ?, ?, 0, ?)',
    );
    _insertForm = _db.prepare(
      'INSERT OR IGNORE INTO forms(form, lemma, pos, note) VALUES(?, ?, ?, ?)',
    );
    _db.execute('BEGIN');
  }

  /// Adds one JSON line. Malformed lines are skipped.
  void addLine(String line) {
    if (line.isEmpty) return;
    lines++;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final word = decoded['word'];
    final rawPos = decoded['pos'];
    if (word is! String || rawPos is! String) return;
    if (_skippedPartsOfSpeech.contains(rawPos)) return;
    final key = PackSchema.key(word);
    if (key.isEmpty) return;
    final pos = _partsOfSpeech[rawPos] ?? rawPos;

    final senses = <Map<String, Object>>[];
    for (final sense in decoded['senses'] as List? ?? const []) {
      if (sense is! Map) continue;
      final glosses = (sense['glosses'] as List? ?? const [])
          .whereType<String>()
          .toList();
      if (glosses.isEmpty) continue;
      final gloss = glosses.last.trim();
      if (gloss.isEmpty) continue;
      final targets = [
        ...(sense['form_of'] as List? ?? const []),
        ...(sense['alt_of'] as List? ?? const []),
      ];
      if (targets.isNotEmpty) {
        for (final target in targets) {
          final lemma = target is Map ? target['word'] : null;
          if (lemma is! String) continue;
          final lemmaKey = PackSchema.key(lemma);
          if (lemmaKey.isEmpty || lemmaKey == key) continue;
          _insertForm.execute([key, lemmaKey, pos, _clip(gloss, 160)]);
          forms++;
        }
        continue;
      }
      final examples = <String>[];
      for (final example in sense['examples'] as List? ?? const []) {
        if (example is! Map || examples.length == 2) continue;
        final text = (example['text'] as String?)?.trim();
        if (text == null || text.isEmpty) continue;
        final english =
            ((example['english'] ?? example['translation']) as String?)?.trim();
        examples.add(
          _clip(
            english == null || english.isEmpty ? text : '$text — $english',
            300,
          ),
        );
      }
      senses.add({
        'd': _clip(gloss, 600),
        if (examples.isNotEmpty) 'e': examples,
      });
    }
    if (senses.isEmpty) return;
    _insertEntry.execute([key, _seq++, word, pos, jsonEncode(senses)]);
  }

  /// Writes the metadata, commits and compacts the file.
  void finish({required String version}) {
    final meta = {
      'schema': '${PackSchema.version}',
      'language': language,
      'name': '$languageName (Wiktionary)',
      'version': version,
      'attribution': 'Wiktionary via kaikki.org, CC BY-SA 4.0 and GFDL',
      'entries': '$entries',
      'forms': '$forms',
    };
    final insertMeta = _db.prepare('INSERT INTO meta(key, value) VALUES(?, ?)');
    for (final MapEntry(:key, :value) in meta.entries) {
      insertMeta.execute([key, value]);
    }
    insertMeta.close();
    _insertEntry.close();
    _insertForm.close();
    _db.execute('COMMIT');
    _db.execute('VACUUM');
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max - 1)}…';
}

/// Streams gzipped kaikki JSON Lines into a new pack at [outputPath].
Future<KaikkiConverter> convertKaikkiGzip(
  Stream<List<int>> gzipBytes,
  String outputPath, {
  required String language,
  required String languageName,
  required String version,
}) async {
  final file = File(outputPath);
  if (file.existsSync()) file.deleteSync();
  final db = sqlite3.open(outputPath);
  try {
    final converter = KaikkiConverter(
      db,
      language: language,
      languageName: languageName,
    )..begin();
    await gzipBytes
        .transform(gzip.decoder)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(converter.addLine);
    converter.finish(version: version);
    return converter;
  } finally {
    db.close();
  }
}
