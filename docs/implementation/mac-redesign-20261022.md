# Mac redesign delivery · 1.26.0

The Mac redesign was laid out in Pen first, following read-only inspection of the official Typeless 2.8.3 bundle. Design rationale, observed reference details and 17 frame IDs are in `docs/design/mac-redesign-20261022.md`. Phone appearance stays unchanged; its transcript presentation components are now shared with Mac.

## Result

- Continuous main/settings windows, native traffic lights and background dragging. The separate titlebar band, horizontal separator and rounded inner-content corner are removed. Settings fills its window rather than centering a fixed-height surface inside the titlebar safe area.
- Main navigation is 15pt with 38pt rows; settings navigation is 14pt with 36pt rows. Home retains one 144pt MoMo, which becomes 56pt at the top of an active conversation.
- Model settings shows readable values while the agent runs. Editing uses the existing custom single-level model selector. Codex/Claude subscriptions precede API; API configuration is a separate page with plain-text return navigation.
- Device management, network details and connection method are distinct pages. Existing QR invitation, number verification, explicit approval and cancellation remain owned by the runtime.
- Advanced settings uses left labels and right capsule actions. The return-control action is contextual to human ownership.
- Transcript history remains in the main sidebar; long-term memory remains in settings. Source links can open original text without merging the two collections.
- Transcript detail shares the phone's date/time header, summary card, audio-card surface/controls, quiet waveform placeholder, text and discussion footer. The original phone rendering values and playback/reading lifecycle remain intact. Mac's current source contract supplies text, so audio is honestly unavailable with `原音在手机`. No duration, audio waveform, time range or paragraph timestamps are invented. Remote text pagination and completion counts remain visible. Discussion creates a draft without submitting it.

## Checks

All checks use default text size, as required by the repository.

| Check | Evidence |
| --- | --- |
| Universal Mac Beta build | `outputs/typeless-chrome-build.log`, succeeded |
| iOS Simulator Beta compilation after shared UI extraction | `outputs/typeless-phone-reuse-build.log`, succeeded; no phone installation |
| Project generation | Pinned XcodeGen 2.46.0; generated changes are limited to the shared source reference |
| Runtime visual review | Main window, enlarged navigation, model, pairing, network/custom address, memory, advanced, onboarding/API |
| Native interactions | Sidebar button and keyboard shortcut; custom model selection and Escape; QR → custom address → back → cancel; separate network pages; API page and plain return |
| Isolated transcript fixture | Completed chat bubbles and compact avatar; transcript list → full text; shared phone-style reader; discussion → retained chat draft; memory star map and list |
| Accessibility evidence | Native AX labels/roles/selected/disabled states inspected; keyboard shortcut and Escape exercised |
| Installation | `/Applications/MoMoAgent Beta.app`, version 1.26.0; strict deep signature verification passed |
| Runtime recovery | One normal-profile Beta process; actual UI returned to `MoMo 正在运行`; fixture profile and server stopped |

`outputs/typeless-chrome-runtime/` contains the actual native screenshots. The fixture uses synthetic text, model choices and loopback responses, without authenticating, submitting a model test or changing the normal profile. Real device removal, permission changes, network-provider changes and model switching were not performed.

Static SwiftUI audit has no high findings; medium findings include intentional desktop dimensions/type sizes and existing geometry/state patterns. No new custom animation, shader or glass effect was introduced, so no frame-rate claim or Instruments result is made. VoiceOver speech, appearance/reduced-effects matrices and physical-phone rendering were not rerun. The conservative rubric is provisional 84/100 (platform 14, layout 14, semantics 13, interaction 18, motion/material 12, accessibility 5, implementation 8); it is evidence-limited, not a claim of a completed Apple-quality certification.

## Delivery and cleanup

The latest signed Mac package is retained under the task's `outputs/mac-beta-1.26.0/`. Obsolete task-owned DerivedData, temporary app copies, the downloaded Typeless reference and extracted bundle files are removed after verification. Installed apps, the existing phone delivery, user data, model resources, private runtimes and pinned tools are preserved. Work is committed and pushed only to `codex/hermes-app-20261021`.
