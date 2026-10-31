# Public M4 source snapshot — 2026-10-31

A curated fast-forward on public `main` from `3d6eb156f86c77a28084f895700bb901a1d7b7c0`, not a merge of private development history. The owner approved the local private acceptance tag `m4-accepted-20261031` and independent public tag `m4-public-snapshot-20261031`. The private accepted commit is `d839fde8d6b7d0a5f88d1f27a93ecc0cf41aac5b`; only the public commit and public tag are sent to GitHub.

## Included and excluded

Retained active production ArkTS/resources, build templates, licenses/provenance and portable host checks remain under the previous reviewed publication boundary. The only production changes since the D4 public snapshot are the accepted E1 Index, ReaderPage and SettingsPage fixes; every retained production file must match the private accepted baseline (Git line-ending normalization aside).

Current status, sanitized M4 acceptance/compatibility summary and M5 preparation routing are updated. Historical AI, private ohosTest/device probes and fixture inputs, raw research/screenshots/logs, signing credentials/certificates, machine-local build profile, signed HAP/APP, actual books/records and historical test directories remain excluded. No private history or local acceptance tag is pushed. The default public build still excludes the private ohosTest module.

## Tests and independent validation

The previous public snapshot had17 portable entrypoints and all remain. The E1 motion test's exact global-animation count changes from3 to2 because Settings now mounts outside the global property-animation transaction; a stronger guard rejects Settings creation inside that transaction. API24 is added to the material fallback rows, and standalone E1 entrypoint18 adds24 controlled cases. This maintenance is separately documented and committed; no production behavior is changed to satisfy an old oracle. See [test maintenance](public-test-maintenance-20261031.md). Public tests match current private test assertions with only the existing TypeScript import adapter. The two private historical visual scripts were not in publicmain at3d6eb15; private35 Pass / 2 Fail remains recorded, not called green.

Independent public validation passed: all18 portable host entrypoints (including24 E1 controlled subcases), SDK26 forced Development default/debug build and production HAP audit at319 warnings/201 fingerprints. Retained111 production ArkTS match the private accepted baseline; curated file scan found no forbidden paths, secret/personal-path findings, new/changed binary assets or broken local Markdown links. An initial sandbox DNS failure prevented npm from obtaining the locked dependency; it was retained as environment evidence, then a normal locked install succeeded and the18-entry gate ran. This is not a host assertion failure or device result. GitHub Actions uses the selected portable host gate; hosted SDK builds remain explicitly disabled, so Actions success cannot mean an SDK or device pass.

Private manual/native evidence is summarized in [status](project-status.md) and [settlement](m4-e4-final-settlement-20261031.md), with errors and package distinctions preserved. Public source sync is not Huawei listing approval, new signed-package device acceptance, GitHub Release creation or App publication.
