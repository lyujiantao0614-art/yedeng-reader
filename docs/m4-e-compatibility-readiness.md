# M4-E compatibility preparation

Date: 2026-10-20. This is a plan and read-only inventory, not a passed runtime matrix.
The current agreed phone acceptance remains in [status](project-status.md).

| Order | Verification | Existing facilities / environment needs |
| --- | --- | --- |
| 1 | Pin source/package/API/ROM and isolated book/record/preferences baseline; verify data failure isolation | Public host/controlled SQLite tests and native build audit; private owner data and historical test folders must remain untouched |
| 2 | API21 then API25 ordinary reading, native overlays, soft-keyboard notes, library/records/settings and fallback | Actual low-version targets preferred; official emulators may supplement install/startup/window checks but are separately labeled |
| 3 | API26 official THICK/ULTRA_THICK material support, unavailable/unsupported fallback, dismissal and theme pairing | Reuse scoped phone evidence where unchanged; source-injected unsupported conditions do not prove a device's native rendering |
| 4 | Tablet portrait/landscape/split/resize, actual usable widths around 600/840vp, Grid, Reader panels, records and settings | Tablet hardware required; applicable foldable device/emulator separately recorded. A phone rotated screenshot is not tablet evidence |
| 5 | Representative cross-page routes and restart persistence on available device/API combinations | Real Entry/four-ArkWeb paths plus isolated storage/failure checks; missing rows stay unverified |

Three routes are enough to begin: (a) scrolled library → EPUB/TXT → notes/bookmarks → centralized records → Reader/back/reopen; (b) isolated tree/import/move/mixed recursive deletion with cancel/failure/retry; (c) book overrides/global settings/theme and window changes → Reader return with saved position/preferences.

Currently only an API26 phone was online at preparation. API21/25 runtimes, tablet hardware and applicable fold/window targets must be supplied before their rows can pass. The installed API21 SDK inventory is not a runtime; keep compile/target26 with compatible21 rather than downgrading the toolchain.

The public repository includes portable host tests; private Hypium/device probes and generated fixtures are excluded. Do not assume a default startup-smoke runner settles M4-E or clear real data to satisfy old fixture guards. Reuse individual existing lab cases after checking their assumptions; keep source, controlled tests, emulator, physical device and owner evidence distinct.

Standard-font ordinary touch, text-field focus/soft keyboard, reading continuity and data safety are required. External keyboard/mouse, screen readers, max/nonstandard fonts and system-animation toggle experiments remain optional. KI-016 and historical SIGABRT are retained, not reopened for a broad diagnostic campaign here. No visual redesign, new global framework, engine rewrite, M5/M6/M7 implementation or release is authorized by this plan.
