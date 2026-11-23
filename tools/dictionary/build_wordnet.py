#!/usr/bin/env python3
"""Builds the bundled English dictionary from Princeton WordNet 3.1.

Output: assets/dictionary/en_wordnet.db.gz, a gzipped read-only SQLite file in
the app's dictionary pack schema (see tools/dictionary/README.md).

Usage:
    python3 tools/dictionary/build_wordnet.py [--dict-dir DIR] [--work-dir DIR]

Without --dict-dir the WordNet 3.1 database files are downloaded to the work
directory (a temporary directory by default) and checked against a pinned
SHA-256. Nothing downloaded is written into the repository.
"""

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import tarfile
import tempfile
import urllib.request

WORDNET_URL = "https://wordnetcode.princeton.edu/wn3.1.dict.tar.gz"
WORDNET_SHA256 = "3f7d8be8ef6ecc7167d39b10d66954ec734280b5bdcd57f7d9eafe429d11c22a"
SCHEMA_VERSION = 1
BUILD_VERSION = "wordnet-3.1-1"

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUT = os.path.join(REPO, "assets", "dictionary", "en_wordnet.db.gz")

POS_FILES = [("noun", "noun"), ("verb", "verb"), ("adj", "adjective"), ("adv", "adverb")]
EXC_FILES = [("noun", "noun"), ("verb", "verb"), ("adj", "adjective"), ("adv", "adverb")]

SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE entries(
  key TEXT NOT NULL,
  seq INTEGER NOT NULL,
  word TEXT NOT NULL,
  pos TEXT NOT NULL,
  rank INTEGER NOT NULL DEFAULT 0,
  senses TEXT NOT NULL,
  PRIMARY KEY(key, seq)
) WITHOUT ROWID;
CREATE TABLE forms(
  form TEXT NOT NULL,
  lemma TEXT NOT NULL,
  pos TEXT NOT NULL DEFAULT '',
  note TEXT,
  PRIMARY KEY(form, lemma, pos)
) WITHOUT ROWID;
CREATE TABLE synsets(id INTEGER PRIMARY KEY, data TEXT NOT NULL);
"""


def download(work_dir):
    archive = os.path.join(work_dir, "wn3.1.dict.tar.gz")
    if not os.path.exists(archive):
        print("Downloading", WORDNET_URL)
        with urllib.request.urlopen(WORDNET_URL) as response, open(archive, "wb") as out:
            shutil.copyfileobj(response, out)
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    if digest != WORDNET_SHA256:
        raise SystemExit(f"Checksum mismatch for {archive}: {digest}")
    target = os.path.join(work_dir, "wn")
    if not os.path.isdir(os.path.join(target, "dict")):
        with tarfile.open(archive) as tar:
            tar.extractall(target, filter="data")
    return os.path.join(target, "dict")


def make_key(word):
    """Mirrors PackSchema.key in lib/features/dictionary/pack/dictionary_pack.dart."""
    word = word.replace("\u2019", "'").replace("_", " ").lower()
    word = re.sub(r"\s+", " ", word)
    return re.sub(r"^[\W_]+|[\W_]+$", "", word)


def display(lemma):
    # Adjective markers such as "(a)", "(p)" and "(ip)" are syntactic notes.
    return re.sub(r"\((a|p|ip)\)$", "", lemma).replace("_", " ")


def parse_gloss(gloss):
    """Splits a WordNet gloss into its definition and quoted examples."""
    gloss = gloss.strip()
    match = re.search(r'(^|;\s*)"', gloss)
    if not match:
        return gloss.rstrip("; "), []
    definition = gloss[: match.start()].strip().rstrip(";").strip()
    examples = [e.strip() for e in re.findall(r'"([^"]+)"', gloss[match.start():])]
    return definition, [e for e in examples if e]


def read_synsets(dict_dir, name):
    synsets = {}
    with open(os.path.join(dict_dir, f"data.{name}"), encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("  "):
                continue  # licence header
            body, _, gloss = line.partition(" | ")
            fields = body.split()
            offset = fields[0]
            count = int(fields[3], 16)
            words = [display(fields[4 + 2 * i]) for i in range(count)]
            definition, examples = parse_gloss(gloss)
            synsets[offset] = (words, definition, examples)
    return synsets


def build(dict_dir, output_db):
    if os.path.exists(output_db):
        os.remove(output_db)
    db = sqlite3.connect(output_db)
    db.executescript(SCHEMA)
    meta = {
        "schema": str(SCHEMA_VERSION),
        "language": "en",
        "name": "English (WordNet 3.1)",
        "version": BUILD_VERSION,
        "attribution": "WordNet 3.1, Princeton University (WordNet licence)",
    }
    db.executemany("INSERT INTO meta VALUES(?, ?)", meta.items())

    entries = 0
    synset_ids = {}
    for name, pos in POS_FILES:
        synsets = read_synsets(dict_dir, name)
        with open(os.path.join(dict_dir, f"index.{name}"), encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("  "):
                    continue
                fields = line.split()
                lemma = fields[0]
                synset_count = int(fields[2])
                pointer_count = int(fields[3])
                tagged = int(fields[5 + pointer_count])
                offsets = fields[6 + pointer_count: 6 + pointer_count + synset_count]
                key = make_key(lemma)
                word = lemma.replace("_", " ")
                refs = []
                for offset in offsets:
                    words, definition, examples = synsets[offset]
                    if word == lemma.replace("_", " "):
                        word = next((w for w in words if w.lower() == word), word)
                    ref = synset_ids.get((name, offset))
                    if ref is None:
                        ref = len(synset_ids) + 1
                        synset_ids[(name, offset)] = ref
                        sense = {"d": definition}
                        if examples:
                            sense["e"] = examples[:2]
                        if len(words) > 1:
                            sense["w"] = words[:8]
                        db.execute(
                            "INSERT INTO synsets VALUES(?, ?)",
                            (ref, json.dumps(sense, ensure_ascii=False, separators=(",", ":"))),
                        )
                    refs.append(ref)
                # Senses are synset ids; the app resolves them through the
                # synsets table and lists the other words as synonyms.
                db.execute(
                    "INSERT INTO entries VALUES(?, ?, ?, ?, ?, ?)",
                    (key, entries, word, pos, tagged, json.dumps(refs, separators=(",", ":"))),
                )
                entries += 1

    forms = 0
    for name, pos in EXC_FILES:
        with open(os.path.join(dict_dir, f"{name}.exc"), encoding="utf-8") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) < 2:
                    continue
                form = make_key(parts[0])
                for lemma in parts[1:]:
                    db.execute(
                        "INSERT OR IGNORE INTO forms VALUES(?, ?, ?, NULL)",
                        (form, make_key(lemma), pos),
                    )
                    forms += 1

    db.commit()
    db.execute("VACUUM")
    db.close()
    return entries, forms


def write_license(dict_dir, target):
    """The WordNet licence must ship with every copy; it heads each data file."""
    lines = []
    with open(os.path.join(dict_dir, "data.noun"), encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("  "):
                break
            lines.append(re.sub(r"^  [0-9]+ ?", "", line).rstrip())
    with open(target, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dict-dir", help="extracted WordNet 3.1 'dict' directory")
    parser.add_argument("--work-dir", help="where to download and build (default: temp)")
    args = parser.parse_args()

    work_dir = args.work_dir or tempfile.mkdtemp(prefix="wordnet-")
    os.makedirs(work_dir, exist_ok=True)
    dict_dir = args.dict_dir or download(work_dir)
    database = os.path.join(work_dir, "en_wordnet.db")
    entries, forms = build(dict_dir, database)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(database, "rb") as source, open(OUTPUT, "wb") as raw:
        # mtime=0 keeps the output byte-for-byte reproducible.
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as out:
            shutil.copyfileobj(source, out)
    write_license(dict_dir, os.path.join(os.path.dirname(OUTPUT), "WORDNET_LICENSE.txt"))
    print(f"entries={entries} forms={forms}")
    print(f"sqlite={os.path.getsize(database)} bytes, gzip={os.path.getsize(OUTPUT)} bytes -> {OUTPUT}")


if __name__ == "__main__":
    main()
