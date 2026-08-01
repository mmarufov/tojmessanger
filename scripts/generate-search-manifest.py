#!/usr/bin/env python3
"""Regenerates Toj/Core/Search/search-tokenizer-manifest.json.

The manifest is the single canonical description of everything that can change what a token is. It
replaced a regex over diff hunks, which could only recognise the token-affecting changes someone
had thought to enumerate — it saw edits to the fold maps but not to `classify`, `forEachToken`, or
the tokenizer configuration itself.

Two halves:

  inputs   `tokenizer` and `normalizerVersion`. Hand-edited, and read by *both* generators so the
           tokenizer string exists in exactly one place instead of being retyped per script.
  digests  Regenerated from the artifacts. Total rather than heuristic:

           tables    every scalar's class and fold, so classification and folding are covered
                     exhaustively rather than by sampling.
           maps      the hand-written Tajik and transliteration tables.
           behavior  the normalizer's actual output — exact form, folded form, and token
                     boundaries — over every vector. This is what covers `forEachToken`: you
                     cannot digest a state machine's source and learn anything, but you can digest
                     what it produces.

Any token-affecting change moves a digest, and `verify-search-tables.sh` then requires
`normalizerVersion` to move with it.

    python3 scripts/generate-search-manifest.py > Toj/Core/Search/search-tokenizer-manifest.json
"""

import hashlib
import json
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "Toj/Core/Search/search-tokenizer-manifest.json")
TABLES = os.path.join(ROOT, "Toj/Core/Search/SearchUnicodeTables.swift")
NORMALIZER = os.path.join(ROOT, "Toj/Core/Search/SearchTextNormalizer.swift")
VECTORS = os.path.join(ROOT, "server/src/search-normalizer-vectors.json")

RECORD = b"\x1d"
FIELD = b"\x1e"
ITEM = b"\x1f"


def load_inputs():
    """Reads the hand-edited half. Kept separate so regeneration never rewrites it."""
    with open(MANIFEST) as handle:
        current = json.load(handle)
    return current["tokenizer"], current["normalizerVersion"]


def swift_array(name):
    source = open(TABLES).read()
    match = re.search(rf"static let {name}: \[UInt32\] = \[(.*?)\n    \]", source, re.S)
    if not match:
        sys.exit(f"{name} not found in {TABLES}")
    return [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]+)", match.group(1))]


def swift_map(name, key_is_scalar):
    """Extracts a hand-written literal map from the normalizer, as sorted (key, value) pairs."""
    source = open(NORMALIZER).read()
    match = re.search(rf"static let {name}: \[[^\]]+\] = \[(.*?)\n    \]", source, re.S)
    if not match:
        sys.exit(f"{name} not found in {NORMALIZER}")
    body = match.group(1)
    pairs = []
    for key, value in re.findall(r'"((?:\\u\{[0-9A-Fa-f]+\}|[^"])+)"\s*:\s*"\\u\{([0-9A-Fa-f]+)\}"', body):
        decoded = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), key)
        pairs.append((decoded, int(value, 16)))
    if not pairs:
        sys.exit(f"{name} parsed to zero entries — the literal format changed")
    if key_is_scalar and any(len(k) != 1 for k, _ in pairs):
        sys.exit(f"{name} has a multi-scalar key")
    return sorted(pairs, key=lambda pair: pair[0].encode())


def digest_tables():
    hasher = hashlib.sha256()
    for name in ("separatorRanges", "ignoredScalars", "foldPairs"):
        values = swift_array(name)
        hasher.update(f"{name}:{len(values)}".encode())
        for value in values:
            hasher.update(struct.pack("<I", value))
    return hasher.hexdigest()


def digest_maps():
    # Sorted by UTF-8 bytes rather than by string: Swift compares Strings under canonical
    # equivalence, so a code-point sort here would disagree with the Swift side on decomposed keys.
    hasher = hashlib.sha256()
    for name, key_is_scalar in (("tajikFolds", True), ("latinDigraphs", False), ("latinLetters", True)):
        pairs = swift_map(name, key_is_scalar)
        hasher.update(f"{name}:{len(pairs)}".encode())
        for key, value in pairs:
            hasher.update(key.encode() + ITEM + struct.pack("<I", value) + FIELD)
    return hasher.hexdigest()


def digest_behavior():
    """Digests what the normalizer produces, which is the only way to cover the token walker."""
    with open(VECTORS) as handle:
        vectors = json.load(handle)["vectors"]
    hasher = hashlib.sha256()
    for vector in sorted(vectors, key=lambda v: v["input"].encode()):
        hasher.update(vector["input"].encode() + ITEM)
        hasher.update(vector["exact"].encode() + ITEM)
        hasher.update((vector["folded"] or "").encode() + ITEM)
        hasher.update(FIELD.join(t.encode() for t in vector["tokens"]))
        hasher.update(RECORD)
    return hasher.hexdigest()


def main():
    tokenizer, version = load_inputs()
    print(json.dumps({
        "note": "Generated by scripts/generate-search-manifest.py. 'tokenizer' and "
                "'normalizerVersion' are inputs, edited by hand and read by both generators. "
                "'digests' are outputs; any token-affecting change moves one, and "
                "verify-search-tables.sh then requires normalizerVersion to move too.",
        "tokenizer": tokenizer,
        "normalizerVersion": version,
        "digests": {
            "tables": digest_tables(),
            "maps": digest_maps(),
            "behavior": digest_behavior(),
        },
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
