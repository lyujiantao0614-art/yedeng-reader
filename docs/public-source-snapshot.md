# Public M4 source snapshot — 2026-10-20

This update is a curated fast-forward on public `main`, not a merge of the private development history. The owner approved this publication boundary and the separate tag `m4-d4-public-snapshot-20261020`.

## Included

Current active production ArkTS/resources, native build metadata/templates, licenses, dictionary provenance and a selected third-party asset provenance extract; self-contained directed host tests with TypeScript 4.9.5; concise M4-D4 acceptance/M4-E next-step documentation. Kept production ArkTS is byte-for-byte identical to the accepted private baseline (Git line-ending normalization aside).

## Deliberately excluded

The private history and local phone acceptance tag; historical AI implementation; private `ohosTest` probes and generated fixture inputs; research/device screenshots, raw logs, signed binaries, credentials/certificates, machine-local signing configuration, real books/records and historical test directories. The public default build target omits the private test module. No new test EPUB or app binary is added.

Only publication/build/test adapters and documentation differ from the retained active application source. The old superseded visual-shape assertions are not used as current acceptance tests; current behavior/data assertions are retained. The shipped original demo is no longer a production input in this source baseline.

## Verification

Host tests: all 17 directed entrypoints passed using the locked dependency. The independent public tree passed the installed SDK26 Development default/debug build and production HAP audit (319 warnings, 201 fingerprints, within the current baseline). The public target excludes private ohosTest; this result does not include device tests or a release build. Public builds use ignored local signing configuration; no signing file or installable artifact is committed.

The curated file audit found no newly added binary assets, credentials, personal absolute paths, signing material, generated books, private probes or raw device evidence. Retained production ArkTS matches the accepted private baseline. UTF-8 and local documentation link checks passed. Git whitespace checks passed outside the pinned epub.js license: its four upstream trailing spaces are retained to preserve the recorded asset hash, rather than rewriting third-party license bytes. Publication uses one new commit descended from the existing public main; private development commits and the phone tag remain excluded.

The accepted private phone binary and this independently built public snapshot are different artifacts. A native compile/audit is not new phone acceptance or API21/25/tablet validation. See [status](project-status.md) for the actual accepted scope and unresolved limits.
