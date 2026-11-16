# Transcript clock and toolbar repair — 0.7.1

The redundant “当天贴纸” jump button is removed from both the phone and Mac transcript toolbars. The illustrations remain accessible in the timeline.

Legacy Mac replicas can arrive before the phone supplies recording timezone metadata. Their UTC timestamps were previously displayed as UTC with “时区待确认” on every row. Missing metadata now uses the Mac's local timezone at the event date, including historical daylight saving. Calendar membership, early-hour grouping, list labels and detail timestamps follow the same clock. Cached old `timezone_unknown` windows and sources without windows also display locally. Explicit recording offsets, including zero, retain priority.

The server marks this read-only projection as `local_timezone`; it does not write an inferred offset into the original source. Projection caches include the local timezone, and recorded and fallback evidence are not merged into the same window. Saved illustration timezones still take priority over a fallback, preserving existing image identity and source anchors. This supersedes the UTC fallback described in `daily-transcript-natural-days-20261116.md`.

Regression coverage exercises old payload formats, local midnight, early-hour folding, summer/winter offsets, explicit UTC, warm-cache timezone changes, same-revision clock enrichment, unchanged source payloads and existing illustration behavior.

## Validation and delivery

- Built signed Release products from `dcb164ee`, version 0.7.1 (internal build 116). Phone and embedded/standalone Watch packages passed 29 bundle checks and signature verification. The two Watch copies matched.
- Passed 20 context tests, 52 illustration tests and 28 XCTest projection/sync cases. Of 42 Swift Testing cases, 41 passed on the first run; the existing multi-day timing benchmark exceeded its warm threshold under concurrent tests (88.30 ms / 80 ms). Its isolated rerun passed: cold 66.90 ms and warm 53.12 ms. Archive implementation was unchanged.
- The Mac bundle passed its offline Python/SuperAgent verifier; its designated signing requirement matched the previous installation. Installed Python sources matched the committed timezone repair.
- Mac and physical phone independently reported 0.7.1 and launched successfully. Mac UI verification showed 09:15–09:21 in both the list and detail, and 09:15:58 on the first span. The redundant jump button and timezone-confirmation label were absent. The physical phone screenshot also showed the local 09:15–09:21 range and no sticker jump button.
- The Mac Agent and tunnel returned online, with the same identity hashes and eight paired-device entries. The phone retained its library identity and all 24,516 baseline chunk IDs. Existing pending recording transfers were not treated as a completed backlog.
- Watch installation returned success against a new installation container. Its subsequent launch and version-readback checks failed because the wireless development service/tunnel disconnected; this run does not establish Watch launch or sustained recording behavior.
- Removed this task's completed DerivedData, package checkouts, Swift test products, temporary bytecode, previous Mac bundle and superseded 0.7.0 delivery bundles. The current 0.7.1 products and small diagnostic evidence remain in the ignored delivery directory; disk availability after cleanup was 12.9 GiB.
