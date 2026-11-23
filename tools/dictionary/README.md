# Dictionary data

Bookmunity looks words up offline. English is bundled with the app; other
languages are optional packs the reader downloads from Settings >
Dictionaries. Everything ends up in the same read-only SQLite layout, read
by `lib/features/dictionary/pack/dictionary_pack.dart`.

## English: WordNet 3.1 (bundled)

`assets/dictionary/en_wordnet.db.gz` is built from Princeton WordNet 3.1:

```bash
python3 tools/dictionary/build_wordnet.py --work-dir /tmp/wordnet
```

The script downloads `https://wordnetcode.princeton.edu/wn3.1.dict.tar.gz`
(16 MB, SHA-256 pinned in the script) into the work directory, never into
the repository, and writes:

- `assets/dictionary/en_wordnet.db.gz`: about 8.3 MB gzipped, 21 MB once
  unpacked. 155,467 headword/part-of-speech entries, 117,791 synsets and
  6,050 irregular forms from WordNet's exception lists.
- `assets/dictionary/WORDNET_LICENSE.txt`: the WordNet licence, which must
  ship with every copy.

The output is byte-for-byte reproducible (fixed gzip mtime). Pass
`--dict-dir` to reuse an extracted `dict/` directory.

At first use the app unpacks the asset into the app support directory as
`dictionaries/en-<version>.db`, off the UI isolate. If you rebuild with
different content, bump `BUILD_VERSION` in the script and
`PackStore.englishVersion` together so installed apps unpack the new copy.

Inflections: the exception lists cover irregular forms (mice, went,
better); `lib/features/dictionary/lookup/english_morphology.dart`
implements WordNet's morphy suffix rules plus undoubling (running, stopped,
bigger), and reduces the first or last word of phrases ("looking up" ->
"look up", "ice creams" -> "ice cream").

## Other languages: Wiktionary via kaikki.org (downloaded)

Packs are converted on the device from kaikki.org's per-language extracts
of English Wiktionary, e.g.
`https://kaikki.org/dictionary/French/kaikki.org-dictionary-French.jsonl.gz`.
The installer (`lib/features/dictionary/pack/pack_installer.dart`) streams
the gzip download through `KaikkiConverter` in a background isolate, so only
the finished pack is written. Form-of senses ("first-person plural present
indicative of manger") become rows in `forms`, which is how inflected words
find their headword.

The catalogue is in `lib/features/dictionary/language_catalog.dart` with the
download sizes measured in November 2026. To check a URL and the conversion
on a desktop with the app's code:

```bash
dart run tools/dictionary/install_pack.dart fr /tmp/packs
dart run tools/dictionary/lookup.dart /tmp/packs/fr.db mangeons yeux "l'homme"
dart run tools/dictionary/convert_kaikki.dart in.jsonl.gz out.db fr French
```

Why not FreeDict: its X->English dictionaries are small for most languages
(Spanish 4,500 headwords, French 8,500, Turkish 1,000) and have no
inflected forms, so most words in a novel would not resolve. Kaikki's
files are larger downloads but give full Wiktionary coverage with
inflections.

## Pack layout

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
-- language, name, version, attribution, schema
CREATE TABLE entries(
  key TEXT NOT NULL,          -- PackSchema.key(word): lower case, no edge punctuation
  seq INTEGER NOT NULL,
  word TEXT NOT NULL,         -- display form
  pos TEXT NOT NULL,          -- noun, verb, adjective, ...
  rank INTEGER NOT NULL DEFAULT 0,  -- WordNet tagged-sense count; 0 for Wiktionary
  senses TEXT NOT NULL,       -- JSON list of {"d","e":[..],"s":[..]} or synset ids
  PRIMARY KEY(key, seq)) WITHOUT ROWID;
CREATE TABLE forms(           -- inflected or variant form -> headword key
  form TEXT NOT NULL, lemma TEXT NOT NULL, pos TEXT NOT NULL DEFAULT '',
  note TEXT, PRIMARY KEY(form, lemma, pos)) WITHOUT ROWID;
CREATE TABLE synsets(id INTEGER PRIMARY KEY, data TEXT NOT NULL);
-- WordNet only: {"d": definition, "e": [examples], "w": [words]}
```

Keys must be produced by `PackSchema.key` (Dart) or `make_key` in
`build_wordnet.py`; the two match.
