# AGENTS.md — public snapshot

Before substantive work read [index](docs/index.md), [status](docs/project-status.md)
and [M5 preparation](docs/m5-search-preparation.md); use [M4-E evidence](docs/m4-e-compatibility-readiness.md) for retained limits. The status distinguishes
implementation, technical verification and owner acceptance.

- HarmonyOS only; native ArkTS/ArkUI, compatible API21, compile/target26. Preserve EPUB/TXT identity and current four-ArkWeb ReaderEngine.
- Reading/dictionary stay local and offline. No account, backend, cloud library, active AI or analytics.
- M4 is formally accepted within the agreed representative scope. Next is M5 preparation only; do not reopen accepted UI or implement M5/M6/M7 without a new execution request.
- Retain settings abilities, saved preferences, records and loss-safe deletion/recovery. Recursive folder deletion uses the complete-book mechanism, never external original files.
- Keep UI → application services → domain → infrastructure. No speculative global framework or engine rewrite.
- Reuse tests; source/controlled boundaries/build/device/user evidence are distinct. Standard-font touch and soft keyboard matter; optional peripheral/font/animation-switch checks do not block delivery.
- Do not log credentials, book text/selections/locators/hashes or private paths. Use isolated owned data for tests.
- No private history/probes/fixtures, credentials, local signing configuration, user data, HAP/APP or logs in commits.
- This public tree intentionally omits private device tests and local research. Do not claim missing tests passed or require their absent files for public CI.
- Run `npm test` for affected host behavior and the documented SDK gate when needed. Documentation edits require UTF-8/link and whitespace checks.
