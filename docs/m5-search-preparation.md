# M5 — full-text search preparation

M4 is owner-accepted within the scope in [status](project-status.md). This document records the next stage only; it does not authorize or claim M5 implementation.

On the next request, first inventory existing publication/section text and offset mapping, query/cancellation/session ownership, original-anchor navigation and reusable tests. Distinguish current-folder title filtering from full-library metadata search and full-text search.

The accepted future scope is full-library metadata, EPUB/TXT single-book and cross-book full text, bounded results/snippets and verifiable exact jumps, including unopened chapters. Preserve Chinese short/single-character, inline-node, repeated-text and Unicode-space semantics; ambiguous/missing anchors must not pretend an exact jump. Indexes are derived data, never record authority. PDF text joins in its later implemented stage; M5 preparation does not start PDF/CBZ/OCR/network/AI development.

Prepare a minimal execution/validation order before new code, reuse current services and fixtures, and retain deletion invalidation, stale-request fencing, memory limits, offline operation and user-data safety. No new budget or universal indexing framework is imposed by this snapshot. Implementation remains for a separate user-authorized task.
