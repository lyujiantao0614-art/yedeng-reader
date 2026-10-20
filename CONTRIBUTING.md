# Contributing

This repository is a reviewed public source snapshot of 页灯 / Yedeng
(`com.yedeng.reader`). Read [AGENTS](AGENTS.md), the [documentation index](docs/index.md),
[current status](docs/project-status.md) and [compatibility scope](docs/m4-e-compatibility-readiness.md).

- HarmonyOS native ArkTS/ArkUI, local-first, minimum API21; ordinary reading and dictionary remain offline.
- Preserve existing EPUB/TXT IDs, locators, note bodies, progress, saved preferences and failure isolation.
- Folder deletion recursively removes managed contents only after explicit confirmation; never delete external originals.
- Keep dependencies directed UI → application services → domain → infrastructure. Avoid unrelated engine or navigation rewrites.
- Record source tests, controlled SQLite tests, SDK builds, isolated UI hosts, real Entry/device checks and human acceptance separately.
- Do not infer API21/25, tablet or foldable support from a phone screenshot or source contract. Do not reopen accepted M4 visual design.
- Never commit credentials, certificates, local signing/configuration, user books/records, binaries, logs or private historical evidence.
- Do not import the private development history. Public updates are curated commits based on public main.

Use the pinned host test dependency with `npm ci --ignore-scripts`, then `npm test`.
Use matching official SDK tools and your own ignored signing profile for native builds.
Source contributions use Apache 2.0; retain third-party provenance and licensing.
