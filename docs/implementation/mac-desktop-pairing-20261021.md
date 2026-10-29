# Mac desktop, pairing and shared phone UI

Feature branch only: `codex/hermes-app-20261021`. Version 1.20.0 (94).

`MoMoAgentMac` provides onboarding, shared MoMo chat, phone-style transcripts,
the original Hermes memory StarMap and later connection management in Settings.
Both Apple clients compile `Apps/ClientUI`; the phone continues owning recording,
ASR and raw audio. Mac reads synchronized text and executes Hermes tasks.

Development launch, after generating the project with XcodeGen 2.46.0:

```sh
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgentMac -configuration Debug -derivedDataPath tmp_agent_output/mac-derived build
tmp_agent_output/mac-derived/Build/Products/Debug/MoMoAgentMac.app/Contents/MacOS/MoMoAgentMac --repository "$PWD"
```

Use `--data-dir` to isolate development fixtures. The app's normal data directory
is `~/Library/Application Support/MoMoAgent/Agent`. Onboarding prepares the
vendored runtime through uv, validates model configuration, starts the Agent,
establishes a temporary HTTPS tunnel and presents a short-lived pairing QR.
Closing the window keeps background work; explicit Quit stops only owned child
processes. This remains a repository-dependent development app, not a signed and
notarized standalone installer.

Access exposes a narrow authenticated forwarding surface. The local control port
is never tunneled. Invitations contain no management credential, expire after five
minutes, and require local approval of matching digits. Phone secrets are hashed
in the pairing store. Revocation invalidates requests; changing a temporary URL
does not change workspace / assistant / instance identity. The temporary SSH
provider can be replaced with an existing HTTPS entry. SSE and cursor recovery
remain the event protocol; no temporary-provider polling fallback was added.

The memory UI build, provenance mapping and upstream license are documented in
`Apps/MacApp/MemoryUI/README.md`. Transcript summaries/previews are intentionally
bounded in the list; the original text reader exposes total characters and
continuation offset, pins the revision and never labels a partial page complete.

Validation: 20 client tests, 18 runtime tests, 1 memory adapter test; Mac Debug,
phone Release and 29 Release audit checks passed. Signed iPhone simulator pairing
image flow passed, including persistent connection after relaunch. Native Mac
transcript and memory/evidence navigation were inspected against synthetic data.
The separate public-tunnel smoke covered authentication, source paging, Hermes
and MCP execution, interim SSE, detached execution, idempotency and revocation.
It used a synthetic model and did not use the user's phone, Watch or personal data.

Remaining: physical camera scan, cellular cross-location test, long sleep/reconnect,
real-model memory quality, audio/Watch status sync to Mac, old Pi data migration and
standalone distribution. Search currently covers synchronized summaries/previews,
not server-side full-text search. These boundaries are explicit in the UI/plan.
