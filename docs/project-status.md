# Project status — 2026-10-31

## Accepted scope

**M4 is formally owner-accepted and complete within the agreed scope:** standard system font, ordinary settings/touch, Mate60 Pro/API26, MatePad Pro/API24, API21 emulator and the representative Mate X5 foldable emulator. This is not acceptance of API25, a physical folding hinge or every device/window combination.

The owner approved the M4-E4 settlement and confirmed that E1/E2/E3 manual results remain valid; do not request those checks again. The next stage is **M5 full-text search preparation only**. No M5 implementation was started by this source sync.

Final active behavior includes EPUB/TXT reading and resume, library organization, explicitly confirmed mixed recursive deletion of managed copies/records with external originals preserved, dismissible partial-failure feedback, centralized reading records with native note/bookmark Tabs, bookmark revalidation and reasonable return state, five Settings categories and per-book overrides.

## Final E1 repairs

- Reader retires the deleted note's Web mark after successful storage commit and session/generation validation; remaining notes and independent highlights survive. No forced book reopen or data-format change.
- In wide two-column Settings, top-level categories are peers: native/system Back exits to the original source. Legal details still return to their matching category; narrow-screen hierarchy is retained.
- Mine → Settings mounts outside the global property animation, with the existing transition confined to the destination. Native press feedback and Reader entry are retained.

The private accepted documentation commit is `d839fde8d6b7d0a5f88d1f27a93ecc0cf41aac5b`, local-only tag `m4-accepted-20261031`. Production source tree: `db4756604f246555506e486db258f965b5787392`; the last production change remains `66dabb31c1d48610296493da0ebc227ab5e04d86`. This public tree is a separate descendant of the previous public main, with its own tag `m4-public-snapshot-20261031`; private history and the private tag are not pushed.

## Evidence boundaries

- Private E4 host checks remain **35 Pass / 2 Fail out of 37**. The two retained failures are obsolete literal-color and delete-button-radius visual oracles, inconsistent with accepted current behavior. They were not fixed by changing production UI and are not called a fully green aggregate gate.
- Private SDK26 Development main/test and Release forced rebuilds and production audits passed at 319 warnings/201 fingerprints. New E4 HAPs were not installed; the Release build is not owner/device acceptance or publishing approval.
- API24 three repairs and other actually checked tablet paths have owner acceptance; API26 directed regressions and prior D4 phone acceptance retain their original package scope.
- E2 original automation is **2 Pass / 5 Error**; owner manual checks cover the remaining library/input/Grid/settings, TOC/semantic resume and draft/IME fold routes. Errors are not rewritten as passes; no physical hinge occlusion was proved.
- E3 original five isolated native data cases passed. The owner separately confirmed normal API21 compliant EPUB/TXT picker import/reading and process-exit/reopen semantic position/per-book settings persistence. The first synthetic EPUB was correctly rejected because its mimetype entry was compressed; the separately corrected file and its later manual acceptance do not erase that failure.
- Public-only validation is recorded in [snapshot scope](public-source-snapshot.md). It has a different portable test selection and no private ohosTest target; do not equate its results with the private 37-entry gate or device tests.

## Risks and next action

API25 runtime, API21 physical hardware, physical fold/hinge/half-fold coverage, every wide-window/theme ratio and arbitrary historical public-data upgrade remain unverified. KI-015 tri-fold resize/gesture recovery, KI-016 stale-chapter flash, historical unlocated SIGABRT, deferred uppercase-ID synthetic samples and old fixture/selector Errors retain their real status. Manual normal behavior does not prove their root causes fixed. Missing API25/hinge environments do not reopen the already accepted representative M4 scope.

Next: [M5 search preparation](m5-search-preparation.md), under a new execution request. Retain local/offline reading and dictionary, EPUB/TXT identity, encrypted records, per-book preferences, sequential migrations and deletion journal/recovery. Do not clear real books/records, legacy credentials or historical test folders to satisfy tests. This source sync creates no GitHub Release, publishes no App and installs no new Release package.
