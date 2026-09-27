#!/usr/bin/env python3
"""Build the pinned Phase 1B OMW + CC-CEDICT dictionary assets.

The script uses only the Python standard library. It verifies every source
before parsing and keeps the differently licensed sources in separate SQLite
files.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sqlite3
import tarfile
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Iterable


OMW_CMN_SHA256 = "7d07af60a6ced0cedc4ca114d0b60a796d3f138df0f3be21f6322e53d004e91c"
OMW_EN_SHA256 = "0e09dfb7f096bc3f10b9de68ffecf13839fa22ae46fd9b227cec890d204ca1dc"
CC_CEDICT_SHA256 = "d0f9d375de2973e5c6e665a96c38e17832d91660ebec1bc918cbc6df80fb2801"

OMW_CMN_URL = "https://github.com/omwn/omw-data/releases/download/v2.0/omw-cmn-2.0.tar.xz"
OMW_EN_URL = "https://github.com/omwn/omw-data/releases/download/v2.0/omw-en-2.0.tar.xz"
CC_CEDICT_URL = "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz"

SCHEMA_VERSION = "1"
SINGLE_WORD_RE = re.compile(r"^[a-z][a-z'-]*$")
CEDICT_LINE_RE = re.compile(r"^(\S+)\s+(\S+)\s+\[(.*?)\]\s+/(.*)/$")
EDGE_PUNCTUATION = "“”‘’\"'.,!?;:()[]{}<>"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_source(path: Path, expected_hash: str, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} source not found: {path}")
    actual_hash = sha256_file(path)
    if actual_hash != expected_hash:
        raise ValueError(
            f"{label} SHA-256 mismatch: expected {expected_hash}, got {actual_hash}"
        )


def safe_extract_tar(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive, "r:xz") as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if os.path.commonpath((str(root), str(target))) != str(root):
                raise ValueError(f"Unsafe archive path: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise ValueError(f"Unsupported archive member: {member.name}")
        bundle.extractall(destination)


def find_single(root: Path, name: str) -> Path:
    matches = list(root.rglob(name))
    if len(matches) != 1:
        raise ValueError(f"Expected one {name} below {root}, found {len(matches)}")
    return matches[0]


def normalize_headword(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold().strip()


def normalize_selected_form(value: str) -> str:
    normalized = normalize_headword(value).strip(EDGE_PUNCTUATION)
    if normalized.endswith("’s") or normalized.endswith("'s"):
        normalized = normalized[:-2]
    return normalized


def clean_chinese_lemma(value: str) -> str:
    return unicodedata.normalize("NFC", value).replace("+", "").strip()


def contains_han(value: str) -> bool:
    for character in value:
        name = unicodedata.name(character, "")
        if name.startswith("CJK UNIFIED IDEOGRAPH") or name.startswith(
            "CJK COMPATIBILITY IDEOGRAPH"
        ):
            return True
    return False


def initialize_database(path: Path, schema: str) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        PRAGMA locking_mode = EXCLUSIVE;
        PRAGMA auto_vacuum = NONE;
        PRAGMA encoding = 'UTF-8';
        PRAGMA user_version = 1;
        """
    )
    connection.executescript(schema)
    return connection


def insert_metadata(connection: sqlite3.Connection, metadata: dict[str, str]) -> None:
    connection.executemany(
        "INSERT INTO metadata(key, value) VALUES (?, ?)", sorted(metadata.items())
    )


def parse_chinese_synsets(path: Path) -> dict[str, tuple[str, ...]]:
    synset_lemmas: dict[str, list[str]] = defaultdict(list)
    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag != "LexicalEntry":
            continue
        lemma = element.find("Lemma")
        written_form = clean_chinese_lemma(lemma.get("writtenForm", "")) if lemma is not None else ""
        if written_form and contains_han(written_form):
            for sense in element.findall("Sense"):
                synset = sense.get("synset", "").removeprefix("omw-cmn-")
                if written_form not in synset_lemmas[synset]:
                    synset_lemmas[synset].append(written_form)
        element.clear()
    return {key: tuple(values) for key, values in synset_lemmas.items()}


def build_omw_database(
    english_xml: Path,
    chinese_synsets: dict[str, tuple[str, ...]],
    output: Path,
) -> dict[str, int]:
    schema = """
    CREATE TABLE metadata(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE meaning(
      headword TEXT NOT NULL,
      part_of_speech TEXT NOT NULL,
      sense_order INTEGER NOT NULL,
      meaning_order INTEGER NOT NULL,
      meaning TEXT NOT NULL,
      synset TEXT NOT NULL,
      PRIMARY KEY(headword, part_of_speech, sense_order, meaning_order, meaning)
    ) WITHOUT ROWID;
    CREATE TABLE inflection(
      surface_form TEXT NOT NULL,
      headword TEXT NOT NULL,
      PRIMARY KEY(surface_form, headword)
    ) WITHOUT ROWID;
    """
    connection = initialize_database(output, schema)
    insert_metadata(
        connection,
        {
            "database_role": "primary",
            "license": "WordNet-style licenses included in THIRD_PARTY_NOTICES.txt",
            "omw_cmn_sha256": OMW_CMN_SHA256,
            "omw_cmn_url": OMW_CMN_URL,
            "omw_cmn_version": "2.0",
            "omw_en_sha256": OMW_EN_SHA256,
            "omw_en_url": OMW_EN_URL,
            "omw_en_version": "2.0",
            "schema_version": SCHEMA_VERSION,
        },
    )

    meanings: set[tuple[str, str, int, int, str, str]] = set()
    inflections: set[tuple[str, str]] = set()

    for _, element in ET.iterparse(english_xml, events=("end",)):
        if element.tag != "LexicalEntry":
            continue
        lemma = element.find("Lemma")
        if lemma is None:
            element.clear()
            continue
        headword = normalize_headword(lemma.get("writtenForm", ""))
        if not SINGLE_WORD_RE.fullmatch(headword):
            element.clear()
            continue
        part_of_speech = lemma.get("partOfSpeech", "u")
        for sense in sorted(element.findall("Sense"), key=lambda item: int(item.get("n", "999"))):
            synset = sense.get("synset", "").removeprefix("omw-en-")
            chinese_lemmas = chinese_synsets.get(synset, ())
            if not chinese_lemmas:
                continue
            sense_order = int(sense.get("n", "999"))
            for meaning_order, meaning in enumerate(chinese_lemmas, start=1):
                meanings.add(
                    (headword, part_of_speech, sense_order, meaning_order, meaning, synset)
                )
        # Keep the English source's evidenced forms even when the matched lemma
        # has no OMW Chinese sense. The product can then resolve the lemma
        # against the separately licensed CC-CEDICT fallback database.
        for form in element.findall("Form"):
            surface = normalize_headword(form.get("writtenForm", ""))
            if SINGLE_WORD_RE.fullmatch(surface) and surface != headword:
                inflections.add((surface, headword))
        element.clear()

    connection.executemany(
        "INSERT INTO meaning VALUES (?, ?, ?, ?, ?, ?)", sorted(meanings)
    )
    connection.executemany(
        "INSERT INTO inflection VALUES (?, ?)", sorted(inflections)
    )
    connection.commit()
    connection.execute("VACUUM")
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise ValueError(f"OMW database integrity check failed: {integrity}")
    counts = {
        "meaning_rows": connection.execute("SELECT COUNT(*) FROM meaning").fetchone()[0],
        "headwords": connection.execute("SELECT COUNT(DISTINCT headword) FROM meaning").fetchone()[0],
        "inflection_rows": connection.execute("SELECT COUNT(*) FROM inflection").fetchone()[0],
    }
    connection.close()
    return counts


def extract_english_gloss_headword(gloss: str) -> Iterable[str]:
    normalized = unicodedata.normalize("NFKC", gloss).casefold().strip()
    normalized = re.sub(r"^(?:\([^)]*\)\s*)+", "", normalized)
    for clause in re.split(r"[;,]", normalized):
        candidate = clause.strip()
        if candidate.startswith("to "):
            candidate = candidate[3:].strip()
        candidate = re.sub(r"\s+\([^)]*\)$", "", candidate).strip()
        if SINGLE_WORD_RE.fullmatch(candidate):
            yield candidate


def chinese_rank(meaning: str, source_order: int) -> tuple[int, int]:
    length = sum(1 for character in meaning if not character.isspace())
    length_priority = {2: 0, 3: 1, 4: 2, 1: 3}.get(length, 4)
    return length_priority, source_order


def build_cedict_database(source: Path, output: Path) -> dict[str, int]:
    schema = """
    CREATE TABLE metadata(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE fallback_meaning(
      headword TEXT NOT NULL,
      meaning_order INTEGER NOT NULL,
      meaning TEXT NOT NULL,
      PRIMARY KEY(headword, meaning_order, meaning)
    ) WITHOUT ROWID;
    """
    connection = initialize_database(output, schema)
    insert_metadata(
        connection,
        {
            "database_role": "fallback",
            "license": "CC BY-SA 4.0",
            "modification": "Strict single-word reverse index with deterministic ranking",
            "schema_version": SCHEMA_VERSION,
            "source_retrieved": "2026-08-14",
            "source_sha256": CC_CEDICT_SHA256,
            "source_url": CC_CEDICT_URL,
        },
    )

    candidates: dict[str, dict[str, int]] = defaultdict(dict)
    source_order = 0
    with gzip.open(source, "rt", encoding="utf-8") as dictionary:
        for line in dictionary:
            if line.startswith("#"):
                continue
            match = CEDICT_LINE_RE.match(line.rstrip())
            if not match:
                continue
            source_order += 1
            simplified = clean_chinese_lemma(match.group(2))
            if not simplified or not contains_han(simplified):
                continue
            for gloss in match.group(4).split("/"):
                for headword in extract_english_gloss_headword(gloss):
                    existing = candidates[headword].get(simplified)
                    if existing is None or source_order < existing:
                        candidates[headword][simplified] = source_order

    rows: list[tuple[str, int, str]] = []
    for headword in sorted(candidates):
        ordered = sorted(
            candidates[headword].items(),
            key=lambda item: chinese_rank(item[0], item[1]),
        )
        for meaning_order, (meaning, _) in enumerate(ordered, start=1):
            rows.append((headword, meaning_order, meaning))

    connection.executemany("INSERT INTO fallback_meaning VALUES (?, ?, ?)", rows)
    connection.commit()
    connection.execute("VACUUM")
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise ValueError(f"CC-CEDICT database integrity check failed: {integrity}")
    counts = {
        "meaning_rows": connection.execute("SELECT COUNT(*) FROM fallback_meaning").fetchone()[0],
        "headwords": connection.execute(
            "SELECT COUNT(DISTINCT headword) FROM fallback_meaning"
        ).fetchone()[0],
    }
    connection.close()
    return counts


def regular_lemma_candidates(surface: str) -> list[str]:
    candidates: list[str] = []
    if surface.endswith("ies") and len(surface) > 3:
        candidates.append(surface[:-3] + "y")
    if surface.endswith("es") and len(surface) > 2:
        candidates.extend((surface[:-2], surface[:-1]))
    if surface.endswith("s") and len(surface) > 1:
        candidates.append(surface[:-1])
    if surface.endswith("ed") and len(surface) > 2:
        candidates.extend((surface[:-2], surface[:-1]))
    if surface.endswith("er") and len(surface) > 2:
        candidates.extend((surface[:-1], surface[:-2]))
    if surface.endswith("est") and len(surface) > 3:
        candidates.extend((surface[:-2], surface[:-3]))
    if surface.endswith("ing") and len(surface) > 3:
        stem = surface[:-3]
        candidates.extend((stem, stem + "e"))
        if len(stem) >= 2 and stem[-1] == stem[-2]:
            candidates.append(stem[:-1])
    return list(dict.fromkeys(candidate for candidate in candidates if candidate))


class PrototypeLookup:
    def __init__(self, omw_path: Path, cedict_path: Path) -> None:
        self.omw = sqlite3.connect(omw_path)
        self.cedict = sqlite3.connect(cedict_path)

    def close(self) -> None:
        self.omw.close()
        self.cedict.close()

    def primary_meanings(self, headword: str, limit: int = 12) -> list[str]:
        rows = self.omw.execute(
            """
            SELECT meaning FROM meaning
            WHERE headword = ?
            ORDER BY part_of_speech, sense_order, meaning_order
            LIMIT ?
            """,
            (headword, limit),
        ).fetchall()
        return [row[0] for row in rows]

    def fallback_meanings(self, headword: str, limit: int = 6) -> list[str]:
        rows = self.cedict.execute(
            """
            SELECT meaning FROM fallback_meaning
            WHERE headword = ?
            ORDER BY meaning_order
            LIMIT ?
            """,
            (headword, limit),
        ).fetchall()
        return [row[0] for row in rows]

    def resolve(self, selected: str) -> tuple[str | None, str | None, list[str]]:
        normalized = normalize_selected_form(selected)
        if not normalized:
            return None, None, []
        meanings = self.primary_meanings(normalized)
        if meanings:
            return normalized, "omw", meanings

        inflected = self.omw.execute(
            "SELECT headword FROM inflection WHERE surface_form = ? ORDER BY headword",
            (normalized,),
        ).fetchall()
        for row in inflected:
            meanings = self.primary_meanings(row[0])
            if meanings:
                return row[0], "omw", meanings
            meanings = self.fallback_meanings(row[0])
            if meanings:
                return row[0], "cc-cedict", meanings

        for candidate in regular_lemma_candidates(normalized):
            meanings = self.primary_meanings(candidate)
            if meanings:
                return candidate, "omw", meanings

        meanings = self.fallback_meanings(normalized)
        if meanings:
            return normalized, "cc-cedict", meanings
        for candidate in regular_lemma_candidates(normalized):
            meanings = self.fallback_meanings(candidate)
            if meanings:
                return candidate, "cc-cedict", meanings
        return None, None, []


def verify_representative_cases(
    cases_path: Path, omw_path: Path, cedict_path: Path
) -> dict[str, object]:
    cases = json.loads(cases_path.read_text(encoding="utf-8"))
    lookup = PrototypeLookup(omw_path, cedict_path)
    categories: dict[str, dict[str, int]] = defaultdict(
        lambda: {"total": 0, "passed": 0, "omw": 0, "cc_cedict": 0, "miss": 0}
    )
    results: list[dict[str, object]] = []
    for case in cases:
        matched, provider, meanings = lookup.resolve(case["term"])
        expected_miss = bool(case.get("expectedMiss"))
        expected_headword = case.get("expectedHeadword")
        passed = not meanings if expected_miss else bool(meanings)
        if expected_headword and meanings:
            normalized_surface = normalize_selected_form(case["term"])
            # The accepted product order checks an exact selected form before
            # lemma fallback. An independently defined surface form is valid;
            # otherwise the evidenced fallback must resolve to the expected
            # base headword.
            passed = passed and matched in {
                normalized_surface,
                normalize_headword(expected_headword),
            }
        category = categories[case["category"]]
        category["total"] += 1
        category["passed"] += int(passed)
        if provider == "omw":
            category["omw"] += 1
        elif provider == "cc-cedict":
            category["cc_cedict"] += 1
        else:
            category["miss"] += 1
        results.append(
            {
                "category": case["category"],
                "term": case["term"],
                "passed": passed,
                "matchedHeadword": matched,
                "provider": provider,
                "meanings": meanings,
            }
        )
    lookup.close()
    return {"categories": dict(categories), "cases": results}


def normalized_license_text(path: Path) -> str:
    return "\n".join(
        line.rstrip() for line in path.read_text(encoding="utf-8").splitlines()
    ).strip()


def write_notices(cmn_license: Path, en_license: Path, output: Path) -> None:
    notice = f"""Harmony AI Reader bundled dictionary notices

The generated dictionary is split into separately licensed database files.

1. omw-en-zh.sqlite3

Derived from Chinese Open Wordnet 2.0 and OMW English Wordnet based on
WordNet 3.0, release 2.0. The transformation keeps aligned English headwords,
part of speech, source sense order, Chinese lemmas and evidenced exceptional
forms. English definitions and examples are omitted.

Chinese Open Wordnet source: {OMW_CMN_URL}
OMW English source: {OMW_EN_URL}

--- Chinese Open Wordnet license ---

{normalized_license_text(cmn_license)}

--- OMW English Wordnet license ---

{normalized_license_text(en_license)}

2. cc-cedict-en-fallback.sqlite3

Derived from CC-CEDICT, published by MDBG, snapshot retrieved 2026-08-14.
Source: {CC_CEDICT_URL}

The source and this transformed fallback data are licensed under the Creative
Commons Attribution-ShareAlike 4.0 International License:
https://creativecommons.org/licenses/by-sa/4.0/

Modification notice: the Chinese-to-English source was transformed into a
strict single-English-word reverse index. Multi-word glosses, pinyin and
entries that do not yield an exact single-word gloss are omitted. Chinese
results are ranked deterministically by concise display length and source
order. No endorsement by MDBG or the CC-CEDICT contributors is implied.

Referenced work retained from the source notice:
CEDICT - Copyright (C) 1997, 1998 Paul Andrew Denisowski.
"""
    output.write_text(notice, encoding="utf-8", newline="\n")


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def build(args: argparse.Namespace) -> None:
    omw_cmn_archive = Path(args.omw_cmn).resolve()
    omw_en_archive = Path(args.omw_en).resolve()
    cedict_source = Path(args.cc_cedict).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    verify_source(omw_cmn_archive, OMW_CMN_SHA256, "Chinese Open Wordnet")
    verify_source(omw_en_archive, OMW_EN_SHA256, "OMW English Wordnet")
    verify_source(cedict_source, CC_CEDICT_SHA256, "CC-CEDICT")

    omw_output = output_dir / "omw-en-zh.sqlite3"
    cedict_output = output_dir / "cc-cedict-en-fallback.sqlite3"
    notices_output = output_dir / "THIRD_PARTY_NOTICES.txt"
    manifest_output = output_dir / "dictionary-manifest.json"
    verification_output = output_dir / "verification.json"

    with tempfile.TemporaryDirectory(prefix="phase1b-dictionary-") as temporary:
        temporary_root = Path(temporary)
        cmn_root = temporary_root / "cmn"
        en_root = temporary_root / "en"
        safe_extract_tar(omw_cmn_archive, cmn_root)
        safe_extract_tar(omw_en_archive, en_root)
        cmn_xml = find_single(cmn_root, "omw-cmn.xml")
        en_xml = find_single(en_root, "omw-en.xml")
        cmn_license = find_single(cmn_root, "LICENSE")
        en_license = find_single(en_root, "LICENSE")

        chinese_synsets = parse_chinese_synsets(cmn_xml)
        omw_counts = build_omw_database(en_xml, chinese_synsets, omw_output)
        cedict_counts = build_cedict_database(cedict_source, cedict_output)
        write_notices(cmn_license, en_license, notices_output)

    verification = verify_representative_cases(
        Path(args.representative_cases).resolve(), omw_output, cedict_output
    )
    write_json(verification_output, verification)

    manifest = {
        "schemaVersion": int(SCHEMA_VERSION),
        "sources": {
            "chineseOpenWordnet": {
                "version": "2.0",
                "url": OMW_CMN_URL,
                "sha256": OMW_CMN_SHA256,
            },
            "omwEnglishWordnet": {
                "version": "2.0",
                "url": OMW_EN_URL,
                "sha256": OMW_EN_SHA256,
            },
            "ccCedict": {
                "snapshotRetrieved": "2026-08-14",
                "url": CC_CEDICT_URL,
                "sha256": CC_CEDICT_SHA256,
            },
        },
        "outputs": {
            omw_output.name: {
                "bytes": omw_output.stat().st_size,
                "sha256": sha256_file(omw_output),
                **omw_counts,
            },
            cedict_output.name: {
                "bytes": cedict_output.stat().st_size,
                "sha256": sha256_file(cedict_output),
                **cedict_counts,
            },
            notices_output.name: {
                "bytes": notices_output.stat().st_size,
                "sha256": sha256_file(notices_output),
            },
        },
        "runtime": {
            "cedict": {
                "bytes": cedict_output.stat().st_size,
                "name": cedict_output.name,
                "sha256": sha256_file(cedict_output),
            },
            "omw": {
                "bytes": omw_output.stat().st_size,
                "name": omw_output.name,
                "sha256": sha256_file(omw_output),
            },
        },
    }
    write_json(manifest_output, manifest)
    print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--omw-cmn", required=True, help="Pinned omw-cmn-2.0.tar.xz")
    parser.add_argument("--omw-en", required=True, help="Pinned omw-en-2.0.tar.xz")
    parser.add_argument("--cc-cedict", required=True, help="Pinned CC-CEDICT gzip snapshot")
    parser.add_argument("--representative-cases", required=True)
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    build(parse_args())
