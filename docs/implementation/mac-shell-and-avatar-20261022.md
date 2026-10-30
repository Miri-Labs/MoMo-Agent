# Mac shell and avatar correction · 2026-10-22

Beta 1.25.1. Hermes remains the integration branch.

## Current interaction contract

The Mac shell follows the supplied Codex reference: a flush sidebar with compact destination rows, one integrated titlebar row, plain settings access and a bordered multiline composer. It keeps the original large MoMo on an empty conversation. The same actor view changes from 144 to 56 points and moves into the header on the first send. The heading slogan was removed; the brand/avatar remain.

Phone chat follows the supplied formal-app reference: the existing actor is 144 points when empty and 84 points during a conversation, with a 72-point compact avatar layout plus name. Header actions share its top row instead of reserving a separate navigation-bar row above it. The watch-status affordance stays attached. Empty-to-chat layout preserves one actor identity and respects reduced motion.

## Missing avatar

Previously, WebKit was the only graphic surface. A page that had not rendered was blank; failures only showed a text placeholder. A native vector from the existing MoMo artwork now paints immediately. The live web surface replaces it only after its SVG geometry exists and the appearance update succeeds. Initial loading, JavaScript failure and web-process termination keep a visible native actor. A single bounded reload handles transient failure, and a generation check prevents an old callback hiding the fallback after invalidation. There is no new artwork or remote dependency.

## Dock icon

The Mac target had no usable Mac icon assignment, while the shared AppIcon is iOS-only. Added a separate MacAppIcon catalog with all ten macOS sizes, derived from the existing brand artwork. Actool now writes CFBundleIconFile and a real MacAppIcon.icns. LaunchServices resolves the brand image instead of its default placeholder. The menu-bar MoMo icon is unchanged.

## Validation and delivery

Mac Beta, iOS Simulator and iPhone Beta builds passed. Installed Mac signature and icon metadata passed; LaunchServices icon rendered to the task evidence folder. Mac runtime checks covered empty/active avatar endpoints, a completed real model reply, repeated sidebar toggles and draft retention when switching between chat and transcripts. The one owned Mac test message/draft were removed only after verifying the cache had no unrelated change.

The simulator journey intentionally disables avatar WebKit in Debug. It asserts visible native-avatar pixels, one avatar identity, 144-point empty layout, 84-point compact layout, horizontal centering and alignment with the header controls. Failure/retry, no task progress or typing flash after completion, swipe keyboard dismissal, memory settings and desktop claim/input/return also passed. Debug-only fault injection is checked by the release bundle audit.

The phone was unavailable on the first install attempt; do not infer installation from the signed build or simulator result. Keep the latest installable artifact if the phone remains disconnected. No dark-mode, VoiceOver or frame-rate performance claim is made from this check.

Design: `docs/design/momoagent-mac.pen`, frames A8A3IN and S1oBUp. The user-provided formal phone screenshot is the phone geometry reference. Source assets, private runtime and model credentials are preserved during cleanup.
