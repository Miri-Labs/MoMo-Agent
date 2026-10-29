# Remote input and durable pairing trust

## Experience contract (before implementation)

Only the remote desktop flow changes. Existing chat, transcript, and phone navigation remain unchanged. Standard profile, default system text size. Phone remote input supports portrait/landscape, touch and physical keyboards. Preview never claims control; explicit Take Control pauses the agent. Return Control is explicit; background/disconnection stops injection, releases held input, and keeps the agent paused until handed back.

Pairing is the durable device authorization. The access service resolves the bearer token against approved devices on every request; only that service asserts paired identity over authenticated private IPC. Do not add another native remote-control approval per session. Revocation still blocks capture and input. macOS Screen Recording and Accessibility are separate OS permissions: first setup or a revoked system permission needs the Mac, but a trusted phone with OS permissions can take over remotely. Polling never reopens permission prompts.

Input is ordered and independent of screenshot cadence: pointer down, coalesced move, pointer up; atomic taps/double-clicks/secondary clicks; targeted two-axis scroll; committed Unicode text and atomic key chords. Keyboard composition stays local until committed; no separate send-text sheet. Never automatically replay uncertain input. Reset held mouse state on cancellation, ownership change and lease expiry. Temporary preview failures recover without permanently poisoning input state.

Pen first: existing preview/control states refined and added direct-keyboard and first-system-permission states in `docs/design/momoagent-mac.pen` (RGCaM, eibyY, Tu7wy, Fes1b).

## Reference inspection

- OpenUUYC v0.7.0, commit 5a9210b: `src/remote_input.rs` separates absolute movement, button down/up, wheel, key down/up and heartbeat from GUI frame cadence. It coalesces movement, preserves input ordering and retires held input at ownership/transport boundaries. `src/controller/takeover.rs` verifies owned devices and confirms takeover on the controller, not a mandatory new host approval for every session. Independent MoMo implementation; no vendor protocol or source copied.
- Installed ChatGPT.app Dots renderer: `src-30df4959c626.js` uses separate mousemove/mousedown/mouseup, wheel axes and keyboard interpretation, observe/control modes, resets keyboard sources and modifiers on focus/source changes. Static local bundle evidence only; no private service calls or claims about newer versions. MoMo keeps its own HTTPS/WebRTC transport and native macOS input host.

- Dots `view-938527becdcf.js` places one floating ownership island immediately below the desktop preview (`top-full`), with a status and Take Over / Return action. Final Pen frames and implementation follow that arrangement: no four-icon mode strip, keyboard in the top-right native toolbar, two-finger tap for secondary click, two-finger drag for wheel, pinch for zoom. Native keyboard accessory owns shortcut modifiers and IME composition.

## Delivery validation

- Beta version 1.26.1. Universal Mac Beta installed with a stable Apple Development signing identity (Team 3WRUNH54B3), replacing ad-hoc signing so updates can retain OS permission identity. Actual system permissions were still absent during this delivery; no real screen capture or OS input is claimed.
- Nine Python bridge tests, 34 AgentClient tests, native input event-collector probe and five private IPC admission/ownership checks passed. Native probe posts no OS events.
- Default-size iPhone simulator UI acceptance passed: preview, explicit takeover/return, tap coordinate conversion, native double-click count, two-finger secondary click, streamed drag, Unicode text, delete/return/tab, Command+A, ordered sequence, temporary frame recovery, first system-permission recovery and revoked-pair repair. No per-session Mac approval request is made. Screenshot evidence is retained outside the repository under the task outputs.
- Both Beta builds and final phone bundle audit passed. Physical phone installation was unavailable at the first attempt because CoreDevice could not connect; installation status is recorded separately from simulator acceptance.
- The existing bounded primary-display JPEG preview remains the media path; input ordering/heartbeat is independent of preview delivery. This change does not claim a new low-latency video transport.
