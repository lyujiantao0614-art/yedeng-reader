# Public host-test maintenance — 2026-10-31

This is a test-only contract update, separate from copying the already accepted E1 production fixes. No production behavior was changed to make an old assertion green.

- The previous public non-reading-motion oracle counted three global shell animation calls. E1 intentionally mounts Settings outside the global animateTo transaction, leaving two calls. Running that old oracle against the accepted E1 source fails with2 !== 3; the original source remains in public history at3d6eb15.
- The current oracle expects exactly two global calls and additionally rejects any Settings destination assignment while global animation is active. Repeat-entry suppression and routing independent of completion callbacks remain asserted. This is the accepted destination-local transition contract, not a looser count bound.
- The material contract adds API24 to the existing API21/API25 low-version no-import/no-new-call rows. No old API26 fallback assertion is removed.
- The existing17 public host entrypoints remain. A standalone E1 regression entrypoint adds24 controlled cases for committed note removal, surviving notes/highlight, failed transaction/read, stale session and wide/compact Settings parent/source Back semantics. They use production-method harnesses, not a private device fixture or a claim of physical-device acceptance.

All public test code matches the current private tests except the pre-existing portable TypeScript import adapter. The private E4 aggregate still reports35 Pass / 2 Fail: its historical literal-color and deletion-radius scripts were already absent from publicmain, not deleted or silently weakened by this sync. Public18-entry success is a different selection and cannot erase those failures.
