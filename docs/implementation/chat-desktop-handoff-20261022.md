# Chat and desktop handoff · 2026-10-22

Hermes branch, Beta 1.25.0 (106). The current user request supersedes the earlier primary memory/progress UI contract.

## Interaction

Both clients use the shared renderer and composer. The reference is the installed Dots bundle: 22-point message corners, quiet surfaces, a 32-point send visual inside a 44-point target. Assistant replies have bubbles as requested; incomplete remote deltas are buffered until a complete message arrives. Busy execution is distinct from waiting for a reply, so tool work or stale running receipts cannot reintroduce typing dots after a reply.

No task-progress UI appears in chat. Durable runs, stop requests, event cursors and background execution remain internal. Failed outgoing messages keep their original operation/payload and show a red retry target. Reads do not replay failed sends; explicit retry preserves idempotency and the existing uncertain-outcome guard.

Phone chat swipes dismiss the keyboard through the transcript WKWebView pan recognizer, without clearing the draft. Memory lives in Settings on both clients. The computer toolbar opens a desktop preview. Pairing management and onboarding share one centered QR/approval flow; custom networking is a secondary page.

Design source: `docs/design/momoagent-mac.pen`, including M04 and the 2026-10-22 chat, desktop and pairing frames. Pen cannot render Chinese reliably on this machine, so design examples use English with Chinese layer names; shipping copy is Chinese.

## Ownership and transport

- The authenticated paired-device API exposes a small desktop route allowlist through the existing HTTPS/WebRTC request transport. Model/provider and tunnel implementations do not enter the native capture/input host.
- The Mac app owns ScreenCaptureKit and accessibility permissions. Pairing is the durable remote-control authorization; 1.26.1 removed the redundant native Mac grant. First-time macOS Screen Recording and Accessibility permissions remain separate; see [remote input repair](remote-input-20261022.md). Root-key-authenticated Unix IPC stays private; no new public listener or screenshot file is created.
- Preview does not acquire control. Explicit claim gives a device a generation/session and pauses the MoMo agent desktop MCP tools. Other viewers cannot capture or inject input during takeover.
- A 20-second lease limits input, with 5-second foreground heartbeats. Expiry pauses input and keeps human ownership; it never silently resumes Agent control. Reclaim or explicit return is available on the phone; Mac Settings/menu also provide return.
- Stale sessions cannot release a new owner. Input is serialized with the lease lock and deduplicated by epoch/event ID. An uncertain input response is not replayed on another transport. Capture revalidates ownership after its asynchronous work.
- These guards cover the MoMo desktop tools, not arbitrary terminal programs or external automation outside that host.

References inspected: ego-lite `helpers.ts` / `browser-runtime.ts` handoff and OpenUUYC v0.7.0 `controller/takeover.rs` / `shared.rs`. Independent implementation; no vendor wire protocol copied. Sources: https://github.com/citrolabs/ego-lite and https://github.com/djkcyl/openuuyc/tree/v0.7.0.

## Validation

29 AgentClient tests, 19 renderer-core tests, 8 desktop lease/bridge tests, 7 runtime tests passed. Native IPC probe passed five ownership checks without screen capture or OS input. WebRTC suite passed with four native-environment scenarios skipped. The final simulator journey passed failure/retry, complete bubbles, no progress/typing flash, keyboard dismissal with retained draft, settings memory, desktop preview, human claim/input/return and one durable submission operation.

Both Beta builds passed and were installed; the phone formal app remains alongside Beta. Installed Mac IPC responded correctly with screen/input permissions still false. Real cross-network screen capture/control has not been accepted on hardware. The initial desktop uses bounded JPEG frames (about two polls/second), not a video media track.

## Repeat the focused tests

Run Python through the prepared runtime using `uv run`. `Tests/AgentRuntime/test_desktop_control.py` exercises lease/bridge behavior. Compile `DesktopControlHost.swift` plus `DesktopControlProbe.swift` to `tmp_agent_output/desktop-control-probe`, then run `run_desktop_control_probe.py`; it creates disposable private state and never posts input.

For the UI journey, start `Tests/AgentRuntime/serve_chat_interaction_fixture.py` with the prepared runtime. It listens only on loopback port 19277 and writes a synthetic pairing manifest to `/tmp/momo-chat-interaction-fixture/phone-pairing.json`. Install a fresh Debug app on an owned simulator and copy that file to its Documents as `momo-simulator-pairing.json`. Run `ChatInteractionTests` through `MoMoAgentRemote`. Restart the fixture and reset only that test app before another run. Close the fixture and remove the owned simulator afterwards.
