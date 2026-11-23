import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Every dictionary (the bundled English one and each downloaded language)
/// is a read-only SQLite file with this layout. tools/dictionary/README.md
/// documents it; tools/dictionary/build_wordnet.py writes the same tables.
abstract final class PackSchema {
  static const version = 1;

  static const statements = [
    'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID',
    // `senses` is a JSON list. Items are either sense objects
    // ({"d": definition, "e": [examples], "s": [synonyms]}) or integer ids
    // into `synsets`, whose words become synonyms.
    'CREATE TABLE entries('
        'key TEXT NOT NULL, seq INTEGER NOT NULL, word TEXT NOT NULL, '
        'pos TEXT NOT NULL, rank INTEGER NOT NULL DEFAULT 0, '
        'senses TEXT NOT NULL, PRIMARY KEY(key, seq)) WITHOUT ROWID',
    // Inflected or variant spelling -> headword key.
    'CREATE TABLE forms('
        "form TEXT NOT NULL, lemma TEXT NOT NULL, pos TEXT NOT NULL DEFAULT '', "
        'note TEXT, PRIMARY KEY(form, lemma, pos)) WITHOUT ROWID',
    'CREATE TABLE synsets(id INTEGER PRIMARY KEY, data TEXT NOT NULL)',
  ];

  static void create(Database db) {
    for (final statement in statements) {
      db.execute(statement);
    }
  }

  static final _marks = RegExp(
    // Combining accents used as stress marks (Russian, Ukrainian), Hebrew
    // niqqud and cantillation, Arabic and Persian harakat. Books are usually
    // printed without them while some headwords carry them.
    '[֑̀́-ׇً-ٰٟ]',
  );

  static final _edges = RegExp(
    r"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$",
    unicode: true,
  );

  /// The lookup key for a headword or a tapped word: lower case, straight
  /// apostrophes, no surrounding punctuation, single spaces.
  static String key(String word) => word
      .replaceAll('’', "'")
      .replaceAll('_', ' ')
      .replaceAll(_marks, '')
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(_edges, '');
}

class PackEntryRow {
  const PackEntryRow({
    required this.key,
    required this.word,
    required this.pos,
    required this.rank,
    required this.senses,
  });

  final String key;
  final String word;
  final String pos;
  final int rank;

  /// Raw JSON list; see [PackSchema].
  final String senses;
}

class PackFormRow {
  const PackFormRow({required this.lemma, required this.pos, this.note});

  final String lemma;
  final String pos;
  final String? note;
}

class PackSense {
  const PackSense(this.definition, this.examples, this.words);

  final String definition;
  final List<String> examples;

  /// Synonyms, or for a synset every word in it (the caller drops the
  /// headword).
  final List<String> words;
}

/// Read access to one pack file.
class DictionaryPack {
  DictionaryPack._(this._db) : meta = _readMeta(_db);

  factory DictionaryPack.open(String path) =>
      DictionaryPack._(sqlite3.open(path, mode: OpenMode.readOnly));

  /// For tests and the converter.
  factory DictionaryPack.fromDatabase(Database db) => DictionaryPack._(db);

  final Database _db;
  final Map<String, String> meta;
  final Map<String, bool> _hasCache = {};

  static Map<String, String> _readMeta(Database db) => {
    for (final row in db.select('SELECT key, value FROM meta'))
      row['key'] as String: row['value'] as String,
  };

  String get language => meta['language'] ?? '';

  List<PackEntryRow> entries(String key, {String? pos}) {
    final rows = pos == null
        ? _db.select(
            'SELECT key, word, pos, rank, senses FROM entries WHERE key = ? '
            'ORDER BY rank DESC, seq',
            [key],
          )
        : _db.select(
            'SELECT key, word, pos, rank, senses FROM entries '
            'WHERE key = ? AND pos = ? ORDER BY rank DESC, seq',
            [key, pos],
          );
    return [
      for (final row in rows)
        PackEntryRow(
          key: row['key'] as String,
          word: row['word'] as String,
          pos: row['pos'] as String,
          rank: row['rank'] as int,
          senses: row['senses'] as String,
        ),
    ];
  }

  /// Whether [key] has an entry, optionally for one part of speech.
  bool has(String key, {String? pos}) => _hasCache.putIfAbsent(
    '$key\u0000${pos ?? ''}',
    () => pos == null
        ? _db.select('SELECT 1 FROM entries WHERE key = ? LIMIT 1', [
            key,
          ]).isNotEmpty
        : _db.select(
            'SELECT 1 FROM entries WHERE key = ? AND pos = ? LIMIT 1',
            [key, pos],
          ).isNotEmpty,
  );

  List<PackFormRow> forms(String form) => [
    for (final row in _db.select(
      'SELECT lemma, pos, note FROM forms WHERE form = ?',
      [form],
    ))
      PackFormRow(
        lemma: row['lemma'] as String,
        pos: row['pos'] as String,
        note: row['note'] as String?,
      ),
  ];

  /// Decodes an entry's senses, resolving synset ids.
  List<PackSense> senses(PackEntryRow row) {
    final decoded = jsonDecode(row.senses);
    if (decoded is! List) return const [];
    final ids = decoded.whereType<int>().toList();
    final synsets = <int, Map<String, dynamic>>{};
    if (ids.isNotEmpty) {
      final placeholders = List.filled(ids.length, '?').join(',');
      for (final synset in _db.select(
        'SELECT id, data FROM synsets WHERE id IN ($placeholders)',
        ids,
      )) {
        synsets[synset['id'] as int] =
            jsonDecode(synset['data'] as String) as Map<String, dynamic>;
      }
    }
    final result = <PackSense>[];
    for (final item in decoded) {
      final map = item is int
          ? synsets[item]
          : item is Map
          ? Map<String, dynamic>.from(item)
          : null;
      if (map == null) continue;
      final definition = (map['d'] as String?)?.trim() ?? '';
      if (definition.isEmpty) continue;
      result.add(
        PackSense(
          definition,
          (map['e'] as List? ?? const []).whereType<String>().toList(),
          (map['w'] as List? ?? map['s'] as List? ?? const [])
              .whereType<String>()
              .toList(),
        ),
      );
    }
    return result;
  }

  void close() => _db.close();
}
