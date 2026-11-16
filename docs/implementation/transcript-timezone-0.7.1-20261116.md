# Transcript clock and toolbar repair — 0.7.1

The redundant “当天贴纸” jump button is removed from both the phone and Mac transcript toolbars. The illustrations remain accessible in the timeline.

Legacy Mac replicas can arrive before the phone supplies recording timezone metadata. Their UTC timestamps were previously displayed as UTC with “时区待确认” on every row. Missing metadata now uses the Mac's local timezone at the event date, including historical daylight saving. Calendar membership, early-hour grouping, list labels and detail timestamps follow the same clock. Cached old `timezone_unknown` windows and sources without windows also display locally. Explicit recording offsets, including zero, retain priority.

The server marks this read-only projection as `local_timezone`; it does not write an inferred offset into the original source. Projection caches include the local timezone, and recorded and fallback evidence are not merged into the same window. Saved illustration timezones still take priority over a fallback, preserving existing image identity and source anchors. This supersedes the UTC fallback described in `daily-transcript-natural-days-20261116.md`.

Regression coverage exercises old payload formats, local midnight, early-hour folding, summer/winter offsets, explicit UTC, warm-cache timezone changes, same-revision clock enrichment, unchanged source payloads and existing illustration behavior. Device delivery and final build results are recorded after validation.
