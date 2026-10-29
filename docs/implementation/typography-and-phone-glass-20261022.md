# Typography and phone header glass · 2026-10-22

Beta 1.25.2 uses the supplied Codex screenshot as a density reference. This is a restrained typography pass, with the existing layout, MoMo geometry, artwork, wordmarks and interaction ownership retained.

## Type hierarchy

| Role | Mac | iPhone |
| --- | --- | --- |
| Conversation and composer | 15 pt | 16 pt |
| Navigation | 13 pt | 16 pt |
| Page heading | 22 pt | 22 pt |
| Secondary heading | 16 pt | 17 pt |
| Section | 14 pt | 16 pt |
| Metadata | 12 pt | 13 pt |
| Caption | 11 pt | 12 pt |

The shared `PhoneTextStyle` keeps platform-specific baselines and its existing scaled metrics. Reading text keeps its paragraph leading; navigation, headings and labels no longer inherit reading-text line spacing. The composer, native initial/failure transcript and WebKit conversation use the same platform baseline. Code remains monospaced at approximately 13/14 points. This is a visual alignment with the reference, not a claim to have extracted Codex's private typography tokens.

## Phone header

Only the phone chat's top-left Settings and top-right Desktop actions receive Liquid Glass. iOS 26+ uses interactive regular glass in circles, within one `GlassEffectContainer`. Both retain their 44-point hit areas and accessibility identifiers/labels. Older iOS uses regular material. Reduce Transparency uses an opaque semantic surface and visible border. No material change is applied to the Mac sidebar or chat bubbles.

## Design and validation

The Pen document `docs/design/momoagent-mac.pen` contains JmImx (Mac typography) and M2PkmM (phone typography/glass). The canvas approximates the material; runtime uses the actual native effect.

Mac Beta and iOS Simulator compilation passed. Renderer core checks passed. Static SwiftUI audit: no high findings; six medium findings for existing fixed avatar/header dimensions and display-symbol sizing. Runtime interaction checks and signed-phone delivery are recorded separately in the task's `outputs/type-glass-*` evidence. No large-font test is added or run, following the repository rule.

The phone UI journey passed after restarting the owned simulator following a test-daemon startup timeout. It covers the header actions, a large/compact visible native-avatar fallback, failed-message retry with one operation identity, completed bubbles, keyboard dismissal with a retained draft, memory settings, and desktop preview/control/return. The signed Beta passed all 29 bundle checks and was installed as 1.25.2; the formal app remains installed. The physical phone was locked when launch was requested, so physical-screen inspection is not claimed.

## Mac pairing controls

Device management lives in the existing compact settings window. Its primary pairing action now reuses the established 52-point capsule style, outside the device list. Device removal is a plain destructive text action. Network setup uses consistent 44-point primary/secondary capsules rather than small default buttons. There is no extra full-page device-management sheet or bottom Done button. QR pairing still has its existing explicit cancellation and approval flow.

Mac Beta was installed as 1.25.2 and its signature verified. Native UI checks covered the compact settings page, paired-device display, the primary action opening a QR invitation, cancellation back to device management, and network disclosure. The existing paired device, credentials and runtime data were retained. No actual device removal or network-provider change was performed.
