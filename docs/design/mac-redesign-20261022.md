# Mac redesign · 2026-10-22

Scope: the Mac app. The phone's appearance, shared chat renderer, original artwork, runtime ownership and network protocols remain outside this visual redesign. At the user's subsequent request, transcript presentation is extracted from the phone into shared components; its local playback and reading-state logic remain with the phone.

## Reference evidence

No public Typeless design-system document was found in the official-site search. Its [settings guide](https://www.typeless.com/help/quickstart/settings) describes the actual settings interactions. The official Apple Silicon download supplied Typeless 2.8.3; the mounted bundle was inspected read-only without installing or launching it.

Observed in `app.asar`:

- Electron windows use a hidden titlebar and native traffic-light controls. The renderer overlays a transparent drag region with no bottom border. Content uses a continuous background with no extra rounded main-content corner.
- The settings row component uses a left title and optional description, with the control on the right. Titles are 14px/20px, medium weight; rows use 9px vertical padding. Section spacing is 40px, and the page title is 24px/32px, medium weight.
- Light surfaces use white and a quiet near-white lower layer. Borders and fills use low-opacity neutrals. Many actions use fully rounded capsules; visual separation does not depend on nesting every setting in a card.
- HTML uses the system font stack. These are observed implementation details, not an official published taste guide.

The design interpretation for MoMo Agent is continuous window chrome, readable current values, restrained rows, localized controls, short copy and one task per page. Typeless code/assets are not included in the product.

## Pen first

`momoagent-mac.pen` contains the full Mac set before implementation:

| Frame | State |
| --- | --- |
| dX6Oq / QCH3v | Empty home / active conversation |
| bX2eu | Transcript timeline and full reader |
| AbMUY / MvC5L | Running model / custom model popover |
| P3mXKg / CnLxi / hEllg | Provider choices / subscription login / API configuration |
| Vt9vN | Runtime preparation |
| ZzXXo / fdtVR / N627U | QR invitation / number confirmation / custom address |
| IKzlQ / hypAW | Device management / network details |
| l1TJZ / BHDzq | Memory / advanced settings |
| jPGET | State and interaction contract |

The older grouped-card settings composition and the new open-row composition were compared. Open rows are selected. The original large MoMo stays on the empty home and the same character shrinks upward during chat. The welcome animation remains the existing implementation.

## Experience contract

- Standard profile; Mac windows, pointer, keyboard and default system text size.
- Main navigation has home and transcripts; settings owns model, pairing, memory and advanced controls.
- No full-width titlebar band, duplicate home heading or decorative rounded inner window. Native window controls and background dragging remain available.
- Model/account/agent state comes from `DesktopModel`. Running models are readable values; editable models use the existing custom single-level selector. No implicit stop or account switch.
- Pairing flows from device management to QR invitation, then number confirmation. Network details and connection method have their own navigation states. Back/Cancel are plain text actions.
- Main sidebar labels use 15pt, settings navigation 14pt with 36pt rows, following the user's size correction. Settings uses 22pt page headings, 14pt rows, 13pt actions, 12pt metadata. Contextual actions use 36pt capsules; primary actions use 44–52pt capsules.
- Loading and errors stay near their owning operation. Existing cancellation, retry, source pagination, permission prompts and destructive confirmations remain intact.
- The empty/active avatar transition retains its current scoped reduced-motion behavior. No new motion or material effect is added.
- Transcript detail shares the phone's date/time header, summary card, audio-player surface and controls, quiet waveform placeholder, transcript text and discussion footer. Mac retains remote text pagination and honest completeness indicators. The current remote source contract has no audio stream, so the player is unavailable with `原音在手机`; duration, peaks and per-paragraph timestamps are not fabricated. Asking opens a draft in Mac chat without sending it.

## Validation

Build, native runtime checks, delivery and cleanup are recorded in `docs/implementation/mac-redesign-20261022.md` and the task's `outputs/typeless-chrome-*` evidence. Default text size only, following the repository rule. No phone rebuild or installation is part of this Mac delivery.
