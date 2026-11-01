# Settings interface polish · 2026-11-01

Baseline: `34c818e6`. Branch: `codex/unslop-ui-preview-20261101`. Reviewed through local screenshots; approved by the user for integration and push on 2026-11-01.

Method: [unslop by Damir Sokolovsky (@heydamir)](https://github.com/heydamir/unslop), CC BY 4.0, adapted to native SwiftUI using the existing MoMo design system. This is a polish pass, not a new visual identity.

## Direction

- Product: a personal agent with continuity across iPhone and Mac.
- Character: quiet, precise, approachable.
- World: ink on paper; grouped controls, readable notes, unobtrusive chrome.
- Moments: finding a setting, checking a source status, reading a memory in full.
- Signature: retain MoMo's existing avatar and Pebble wordmark; settings and reading surfaces use the system typeface.

## Audit

- Phone settings: 58 pt rows and 20 pt gray containers dominate a narrow screen; transcript rows omit the icon column used by other groups.
- Phone settings: 24 pt page gutters and 18 pt row gutters accumulate; values compete with titles when long.
- Phone memory: already uses a readable list with full-text navigation. Only refine spacing and metadata; preserve original content and all actions.
- Mac settings: 240 pt sidebar consumes almost a third of the default 820 pt window; search and rows use different horizontal alignments.
- Mac controls: runtime picker and proxy menu use different visual treatments; subtle border/hover treatment should be consistent.
- Both: retain semantic colors, native focus/controls, section order, state ownership, and existing brand. No decorative gradients, imagery, animation or extra explanatory copy.

## Review scope

Phone settings and memory; Mac general/model/device settings. Synthetic phone memory fixture and an isolated Mac data directory for screenshots. Runtime screenshots are UI validation, not real-device acceptance or proof of agent connectivity. Default text size only, per repository policy.

## Changes

| Pass | Applied change |
| --- | --- |
| Spacing | Phone rows 58 → 52 pt; page gutters 24 → 20 pt; section gap 28 → 24 pt. Mac sidebar 240 → 208 pt, shared content gutter 28 pt. |
| Color | Phone groups use the existing paper/line tokens; Mac controls use quiet neutral fills. Increased-contrast borders retain an explicit stronger variant. |
| Icons | Phone settings share a 20 pt icon column. Memory uses a book icon; transcript settings now align with the other groups. |
| Copy | Existing settings, source-status wording, actions and memory text are preserved. |
| Type | Native inline phone title removes the separate title block. Mac page titles share 20 pt semibold; navigation/controls 13 pt. Phone reading text retains its existing scaling. |
| Layout | Inset separators align with phone labels; values can wrap. Mac model, device and memory headings align with general settings. |
| Details | Runtime selector matches the proxy menu. Mac controls share 28 pt minimum height, 8 pt radius and restrained hover/press borders. |
| Visuals | Existing MoMo palette and brand retained. No generated imagery or added decoration. |
| Motion | Native navigation and menus retained; no custom motion added. |

## Screenshots

These are real app screenshots, not mockups. Phone uses the loopback memory fixture on an iPhone 17 simulator (iOS 27); Mac uses an isolated, unpaired data directory. The purple capsule in the Mac window is a system capture indicator, not MoMo UI.

- [Phone settings before](screenshots/phone-settings-before.png) · [after](screenshots/phone-settings-after.png)
- [Phone memory before](screenshots/phone-memory-before.png) · [after](screenshots/phone-memory-after.png)
- [Original full memory](screenshots/phone-memory-detail-after.png) · [long memory scrolling](screenshots/phone-memory-long-after.png)
- [Mac general before](screenshots/mac-before.png) · [after](screenshots/mac-after.png)
- [Mac model](screenshots/mac-model-after.png) · [Mac devices](screenshots/mac-devices-after.png)

## Validation

- Mac Debug build passed. Actual 820 × 560 pt settings window inspected; general/model/device navigation, search + Return, search clear, runtime menu open/cancel verified. No engine switch or model login performed.
- iOS Debug build passed. `MemoryReadingTests.testPreviewFullTextAndReversibleActions` passed in light appearance, including original full text, long-text preservation, repeated navigation, cancel-delete, and contrast/hit-region/trait accessibility audit on memory list.
- Initial unsigned simulator baseline did not establish the fixture connection. Rebuilding with normal simulator signing resolved it; signed baseline passed before UI edits. No connection-product code was changed.
- SwiftUI static audit: no high-severity findings. Medium flags were reviewed: fixed icon/sidebar/control dimensions and native Mac type sizes; unrelated existing screen findings were not broadened into this polish task. This is not a claim of complete VoiceOver or all-window-size acceptance.
- Mac dark-mode launch argument did not change actual appearance, so it is not reported as a dark-mode pass. No global system appearance setting was changed.
- Existing project-group and WebKit delegate build warnings remain; no new compile errors.
- Public version remains 0.0.1. This change ships source and review evidence; no device installation or new installation package is included.

Reference snapshot: unslop `1d13095`; attribution and adapted scope above. No image-generation prompts were used.

Phone dark appearance was also verified using `simctl ui appearance dark`: the same reading/navigation/accessibility test passed (56.418 s). [Settings](screenshots/phone-settings-dark.png) · [Memory](screenshots/phone-memory-dark.png).

## Cleanup

Stopped the local fixture and the stalled unsigned-test diagnostics process, deleted the dedicated simulator, and removed this task's build/package caches, temporary fixture files, unslop reference clone and borrowed dependency symlinks. Shared models, installed apps, private runtime and the other active build were preserved. Screenshots and concise validation evidence total approximately 2.2 MB. Available disk space was 8.0 GiB at the final check; another build was active, so this is not attributed entirely to this cleanup.

The approved source and review evidence are committed together. Rebuilding an isolated task worktree requires reconnecting the existing primary checkout's `Models`, `Vendor/SherpaOnnx/Binaries`, and `Vendor/TailscaleKit/Build` resources. They were unlinked from this worktree, not deleted.
