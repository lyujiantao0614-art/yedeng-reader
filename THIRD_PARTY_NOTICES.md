# Third-party notices

This file is the repository-level inventory for software and data used by the
project. The project source is licensed under Apache-2.0, but that license does
not replace the licenses of the items below.

The application package also retains full license or attribution text beside
the assets where required. This inventory is not a substitute for those files.

## Runtime software

| Component | Version | Use | License | Evidence and retained license |
| --- | --- | --- | --- | --- |
| epub.js | 0.3.93 | Local EPUB parsing and rendering inside ArkWeb | BSD-2-Clause | [Pinned-asset record](docs/research/web-reader-engine-third-party.md) and [vendored license](entry/src/main/resources/rawfile/web-reader/vendor/epubjs-0.3.93/LICENSE) |
| JSZip | 3.10.1 | ZIP implementation used by epub.js | MIT OR GPL-3.0-or-later; this project uses the MIT option | [Pinned-asset record](docs/research/web-reader-engine-third-party.md) and [vendored license](entry/src/main/resources/rawfile/web-reader/vendor/jszip-3.10.1/LICENSE.markdown) |

The pinned source archives, integrity values and vendored-file SHA-256 hashes
are recorded in the linked research file. Neither component is downloaded at
runtime.

## Development dependencies

| Component | Version | Use | License | Locked source |
| --- | --- | --- | --- | --- |
| @ohos/hypium | 1.0.24 | HarmonyOS test framework | Apache-2.0 | oh-package-lock.json5 |
| @ohos/hamock | 1.0.0 | HarmonyOS mock framework | Apache-2.0 | oh-package-lock.json5 |

The lockfile records the package registry locations and SHA-512 integrity
values. Installed copies contain their Apache-2.0 license files; generated
oh_modules content is not committed.

## Bundled dictionary data

The two generated dictionary databases remain separate because their source
families have different licenses.

### Chinese Open Wordnet and OMW English Wordnet

- Generated asset: omw-en-zh.sqlite3.
- Source release: OMW 2.0, including Chinese Open Wordnet 2.0 and OMW English
  Wordnet based on WordNet 3.0.
- License: the respective Chinese Open Wordnet and Princeton WordNet license
  texts retained in the packaged dictionary notices.
- Transformation: aligned English headwords, part of speech, source sense
  order, Chinese lemmas and evidenced exceptional forms are retained; English
  definitions and examples are omitted.

### CC-CEDICT

- Generated asset: cc-cedict-en-fallback.sqlite3.
- Pinned source: MDBG snapshot retrieved on 2026-08-14.
- License: Creative Commons Attribution-ShareAlike 4.0 International.
- Transformation: strict single-English-word reverse index; multi-word
  glosses, pinyin and non-exact candidates are omitted, with deterministic
  ranking for concise display.

The complete source URLs, copyright notices, license text and modification
notice are retained in
[the packaged dictionary notices](entry/src/main/resources/rawfile/dictionary/THIRD_PARTY_NOTICES.txt).
The pinned source hash and deterministic rebuild instructions are recorded in
[the dictionary source record](third_party/dictionary/README.md).

## Fonts, models and user content

- The project currently bundles no project-selected font file. The UI uses
  system fonts; fonts embedded in user-imported EPUBs remain part of that user
  content and are not extracted or relicensed by the project.
- The project currently bundles no local machine-translation model.
- A future software dependency, dataset, font, icon, model or media asset must
  have its source, version, license, required attribution, integrity value and
  package impact reviewed before distribution.
