# Phase 1B bundled dictionary data

The Phase 1B dictionary package is generated from two separately licensed
source families and remains split into two SQLite files:

- `omw-en-zh.sqlite3`: Chinese Open Wordnet 2.0 aligned with OMW English
  Wordnet 2.0;
- `cc-cedict-en-fallback.sqlite3`: a strict single-word English reverse index
  of the pinned CC-CEDICT snapshot.

The generated databases and bundled notices live under
`entry/src/main/resources/rawfile/dictionary/`. The application must preserve
the source order: OMW is the primary sense-aware result and CC-CEDICT is a
bounded local fallback.

## Pinned source

`sources/cc-cedict-2026-08-14.txt.gz` is the exact MDBG snapshot retrieved on
2026-08-14. It is retained because the official download URL is rolling.

SHA-256:

```text
d0f9d375de2973e5c6e665a96c38e17832d91660ebec1bc918cbc6df80fb2801
```

The immutable OMW 2.0 release archives are downloaded into ignored build
output by `tools/prepare-phase-1b-dictionary.ps1`; their expected hashes are
enforced by the generator.

## Rebuild

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tools/prepare-phase-1b-dictionary.ps1
```

This performs a maintainer-time deterministic generation step. The product
does not parse XML, reverse CC-CEDICT or build an index at runtime.

## Licenses and transformation

The exact source license text, attribution and transformation notice are
bundled in `THIRD_PARTY_NOTICES.txt` beside the databases. The OMW-derived and
CC-CEDICT-derived records are deliberately not merged into one database.

CC-CEDICT and its transformed fallback database are licensed under CC BY-SA
4.0. Changes consist of retaining only exact single-English-word glosses,
omitting multi-word glosses and pinyin, and applying deterministic ranking for
concise display.

Do not replace either source or regenerate a published database without a new
hash, coverage, quality, size and license review.
