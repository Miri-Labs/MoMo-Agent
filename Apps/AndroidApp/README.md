# MoMo Agent for Android

Version 0.6.0. This is the iPhone app's Android port, not a second design:
the welcome/connection/chat structure, chat renderer, avatar, wordmark, receipts,
composer and settings follow the iPhone client. It talks to the Mac hub over the
existing access contract; the Mac keeps running the Agent and the memory vault.
## Flow

```text
Welcome experience → Connection flow → Chat / Transcripts / Memory tabs → Desktop / Settings
```

- Welcome: the same three scenarios and copy as the iPhone introduction, with the
  live MoMo avatar, a static fallback and a Continue button for each scene. Brand SVGs are
  pre-rendered to tintable PNGs because AndroidSVG clipped the outlined wordmark
  and the still on device.
- Connection: scan the Mac pairing QR; pending pairing survives restarts and
  resumes on foreground. A manual connection form lives in Settings.
- Chat: the iPhone's Web renderer is reused from `assets/chat`, fed by the same
  snapshot fields (Markdown, tools, attachments, `已送达`/`已读`, waiting dots).
  The avatar, settings and task/desktop controls float over the scroll view;
  the composer has its own space below the conversation. The tab bar hides while
  the IME is open so the composer sits above the keyboard.
- Transcripts: a day/window timeline grouped by recording day with previous/next
  day, a date picker and full-text search. A recording with several windows
  produces one row per window; opening a row scrolls the detail to that window.
  Details render each span's time and known speaker, load every server page
  instead of stopping at 12,000 characters, and offer "Ask about this section"
  citations. Android has no local recording/ASR yet; local transcripts are a
  separate slice.
- Memory: read-only long-term memory from the Mac context API.
- Settings: Mac connection state, reconnect, re-pair, manual configuration,
  network route/address, version and unpair. Unpair first calls `POST /pair/revoke`
  so the Mac also drops the device grant; the local credential is cleared only
  after the Mac confirms (401/404 is treated as already revoked).

## Pairing modes

- `lan`: the Mac's self-signed TLS endpoint; the app pins the `tls_sha256`
  fingerprint from the QR and rejects plaintext or public LAN addresses.
- `tailscale`: an embedded-Tailscale `http://100.64.0.0/10:8767` invitation; the
  phone must have the system Tailscale app signed into the same tailnet.
- `relay`: intentionally rejected in this preview.

The debug build allows cleartext only for the Tailscale system-VPN case; the
release network policy must be narrowed before shipping (tracked in the todos).

## Chat contract

- `GET /momo/v1/conversation/snapshot` loads server messages, runs, background
  work, message states and provider notices.
- `GET /momo/v1/conversation/subscribe?after=` keeps a cursor-based SSE
  subscription with reconnect backoff.
- `POST /momo/v1/conversation/messages` sends `{operation_id, content, intent}`
  plus optional attachments; optimistic messages are replaced by the server echo.
- Receipts resolve to `delivered`/`read` from message states and run generation;
  the Web renderer owns the three-dot waiting bubble.
- Attachments: images (JPEG/PNG, 1 MB, 64 KB preview) and plain text documents
  (256 KB), up to four.

## Source layout

```text
app/src/main/assets/chat/        # copied iPhone Web renderer + avatar
app/src/main/assets/brand/       # Pebble wordmarks and MoMoStill SVG
app/src/main/java/com/momoagent/android/
├── data/                        # wire models, HTTP/SSE, pinned TLS, Keystore
├── remote/                      # PairingManager, ConversationStore, ContextStore
└── ui/                          # Welcome, Connection, Chat, Memory, Transcripts, Settings
```

The renderer and brand assets are copied from the iPhone target so both clients
render the same content. Update both when the iPhone Web renderer changes.
For Android, transform the shared `vendor/marked.js` with esbuild 0.25.12
(`--target=chrome83 --minify --legal-comments=inline`), wrap the output in an IIFE to isolate compiler helpers, retain the upstream
license header and update the Android vendor manifest hash. The WebView
compatibility script runs before the renderer and avatar.

## Build and verify

```sh
cd Apps/AndroidApp
gradle :app:assembleDebug
gradle :app:testDebugUnitTest
gradle :app:lintDebug
```

Current results: `assembleDebug` produces `app-debug.apk` (`com.momoagent.android`,
version 0.6.0, versionCode 8, minSdk 26, targetSdk 35); 32/32 JVM tests pass;
lint reports 0 errors and 30 warnings. There is no device/emulator end-to-end
run yet.

The Settings header and About row read `BuildConfig.VERSION_NAME`; the
`0.1.0` fallback is gone. The Welcome and Connect screens also show the version
at the bottom. If a phone keeps displaying an old version after an install, the
old package is still the one running: uninstall it and install the new APK
(unpairing is local to the phone; scan the Mac QR to pair again).

## Mac desktop

The chat header's desktop button opens a full-screen viewer backed by
`GET /desktop/v1/frames`, the Mac's multipart JPEG stream. Only two
unacknowledged pictures are allowed, so the client acknowledges each rendered
frame with `POST /desktop/v1/frame-ack`. Taps, double taps, drags, scroll mode
and right clicks are normalized to image coordinates and sent through
`POST /desktop/v1/input`; input coordinates ignore letterboxing.

"Take control" claims the Mac desktop lease (`claim`), heartbeats every five
seconds (`heartbeat`) and releases it on exit (`release`). Without a claim the
viewer stays read-only. Screen Recording or Accessibility permissions are
checked by the Mac when claiming; failures stay visible in the viewer instead
of falling back to the old "not available" dialog.

## Interface

The Android client uses the shared neutral canvas, paper, ink and divider colors
in light and dark mode. Transcripts and memories use reading rows. Navigation,
the composer and the connection popover use a paper fill and a thin outline.
The desktop viewer fits the Mac frame above its controls in portrait and places
the tools beside the frame in wide landscape windows.

## Known gaps

- Local recording, on-device ASR, speaker diarization and local transcripts.
- Watch/earphone capture status, life illustrations and dream briefing cards.
- Chat voice dictation, push notifications, relay transport and an iOS LAN client.
- Release signing and a narrowed production network policy.

## License

AGPL-3.0-only, matching the rest of the repository.
