# MoMo Agent for Android

Version 0.3.1. This is the iPhone app's Android port, not a second design:
the welcome/connection/chat structure, chat renderer, avatar, wordmark, receipts,
composer and settings follow the iPhone client. It talks to the Mac hub over the
existing access contract; the Mac keeps running the Agent and the memory vault.
Version 0.3.x adds the iOS 26-style liquid-glass treatment from the reference
video to the floating controls and cards; 0.3.1 fixes the version display.

Status: **built and unit-tested; not yet run on a physical device or emulator in
this checkout.**

## Flow

```text
Welcome experience → Connection flow → Chat / Transcripts / Memory tabs → Settings
```

- Welcome: the same three scenarios and copy as the iPhone introduction, with the
  live MoMo avatar and a static `MoMoStill` rendered behind it. Brand SVGs are
  pre-rendered to tintable PNGs because AndroidSVG clipped the outlined wordmark
  and the still on device.
- Connection: scan the Mac pairing QR; pending pairing survives restarts and
  resumes on foreground. A manual connection form lives in Settings.
- Chat: the iPhone's Web renderer is reused from `assets/chat`, fed by the same
  snapshot fields (Markdown, tools, attachments, `已送达`/`已读`, waiting dots).
  The avatar, settings and task/desktop controls float over the scroll view;
  the composer and the tab capsule are glass surfaces. The tab bar hides while
  the IME is open so the composer sits above the keyboard.
- Transcripts: read-only list of sources synced to the paired Mac. Android has no
  local recording/ASR yet; local transcripts are a separate slice.
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

## Build and verify

```sh
cd Apps/AndroidApp
gradle :app:assembleDebug
gradle :app:testDebugUnitTest
gradle :app:lintDebug
```

Current results: `assembleDebug` produces `app-debug.apk` (`com.momoagent.android`,
version 0.3.1, versionCode 6, minSdk 26, targetSdk 35); 24/24 JVM tests pass;
lint reports 0 errors and 30 warnings. There is no device/emulator end-to-end
run yet.

The Settings header and About row read `BuildConfig.VERSION_NAME`; the
`0.1.0` fallback is gone. The Welcome and Connect screens also show the version
at the bottom. If a phone keeps displaying an old version after an install, the
old package is still the one running: uninstall it and install the new APK
(unpairing is local to the phone; scan the Mac QR to pair again).

## Liquid glass

`ui/Glass.kt` draws the translucent gradient, top specular bloom, bright rim and
soft ambient shadow; pressed controls use a spring scale and highlight bloom.
The floating header, tasks capsule, desktop button, tab capsule, composer,
connection popover, banners, page headers, memory search, cards and dialogs use
it. The chat page is transparent and passes a `headerInset` so messages start
below the floating avatar and scroll under it.

Android Compose has no backdrop-filter equivalent. The app therefore uses a
low-contrast ambient backdrop plus a fade scrim behind the floating controls
instead of a true blur of the content underneath. Chat bubbles, attachments and
transcript/memory content stay solid, matching the reference video; only the
chrome is glass.

## Known gaps

- Local recording, on-device ASR, speaker diarization and local transcripts.
- Watch/earphone capture status, desktop control, life illustrations and dream
  briefing cards.
- Chat voice dictation, push notifications, relay transport and an iOS LAN client.
- Release signing and a narrowed production network policy.

## License

AGPL-3.0-only, matching the rest of the repository.
