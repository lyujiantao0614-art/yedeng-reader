# Project status — 2026-10-20

## Accepted scope

**M4-D4, including D4-4, is complete for the agreed Mate60 Pro/API26 phone scope.**
The owner personally operated the final installed candidate and confirmed the reported issues were repaired and the experience was normal. Earlier reading, records, appearance, management and settings did not show a confirmed new regression in that acceptance.

- Book deletion publishes Grid changes; success uses an expiring native toast and partial failure is dismissible/retryable.
- Books and folders support mixed selection. Confirmed folder deletion recursively deletes managed imported copies and their records, deduplicates descendants, and leaves external original files unchanged. Failed/nonempty/changed trees are not prematurely removed.
- Mine has one reading-records entry; native note/bookmark Tabs support click/swipe without custom gesture simulation.
- Returning from Reader revalidates centralized bookmark data while retaining the visit and reasonable tab/page/scroll state; stale requests and failed reads do not clear committed records.
- Accepted native details, reading panels, appearance and settings retain existing storage and engine semantics.

## Evidence boundaries

The private accepted development baseline is `9f3cf4f228801d406a24b4975626fb29813c3c05`.
Its local phone tag is `m4-d4-phone-accepted-20261020`; it is intentionally not pushed because it reaches private history. This public snapshot uses `m4-d4-public-snapshot-20261020` instead.

- Private baseline: Development main/test builds and production audit passed with 319 warnings/201 fingerprints; 11 directed host entries passed at closeout.
- Exact private candidate device evidence: two normal Entry/Reader record-return cases and two isolated production-component cases passed. The actually scrolled page-2 bookmark return measured 0px relative displacement; these four are not one all-app end-to-end suite.
- Owner phone acceptance is separate from automated results. Historical fixture/input/assertion Errors remain recorded privately; they were not converted to passes.
- Public snapshot validation is recorded in [scope/verification](public-source-snapshot.md). It does not imply the public build was installed or independently accepted on every device.

## Remaining M4 work

**M4 overall is not complete. M4-E compatibility verification is next; only read-only preparation has occurred.** API21/25 runtime behavior, tablets, wide windows and applicable foldable scenarios remain unverified for this candidate. SDK26/compatible21 declarations and controlled material tests are not device evidence.

KI-016 stale-chapter flash, historical unlocated SIGABRT, and deferred uppercase-ID legacy sample behavior remain unresolved within their original scope. A few initial record screenshots had transient icon/title observations; later frames were normal and the owner accepted actual use. No separate root-cause repair is claimed for those observations.

Next action: establish the exact package/isolated data baseline, then follow [M4-E sequence](m4-e-compatibility-readiness.md). Do not reopen accepted visual design, develop M5/M6/M7, publish an App release, uninstall or clear real/old test data as part of this source sync.
