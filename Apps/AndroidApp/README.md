# MoMo Agent for Android (Preview)

This is the first Android slice of MoMo Agent. It is a client for the Mac hub,
not a second agent runtime. It pairs with an existing Mac installation, loads
the shared conversation, sends a message, and renders the same server-sent
events the Apple clients already consume.

Status: **preview, not device-verified yet**. The current slice covers pairing,
secure credential storage, conversation snapshot, sending, streaming replies,
and unpairing. Recording, on-device transcription, memory, illustrations,
proactive notifications, attachments, relay transport, and Wear OS are not
implemented. See `docs/todos/android-client.md`.

## Requirements

- JDK 17 or newer.
- Android SDK Platform 35 and Build Tools 35.
- A Mac running MoMo Agent with remote access enabled.
- For the `tailscale` network invitation, the Android device must be connected
  to the same tailnet through the Tailscale app. Relay invitations are rejected
  in this preview.

## Build

```sh
cd Apps/AndroidApp
./gradlew :app:assembleDebug
```

The APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

Install on a connected device:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` is ignored. Point it at your SDK when Gradle cannot find one:

```properties
sdk.dir=/path/to/Android/sdk
```

## Pairing

1. On the Mac, open MoMo Agent and show the pairing code.
2. On Android, tap **Scan pairing code** and point the camera at the QR code,
   or paste the JSON payload into the text field.
3. Confirm the numeric code shown on both devices, then approve on the Mac.
4. The credential and connection are stored in
   `EncryptedSharedPreferences`, backed by the Android Keystore.

The client accepts HTTPS endpoints and loopback HTTP for local development.
Cleartext traffic is disabled by default and allowed only for `localhost` and
`127.0.0.1` in the network security config.

## Layout

```text
app/src/main/java/com/momoagent/android/
├── MainActivity.kt
├── data/
│   ├── AgentApi.kt        HTTPS and SSE client
│   ├── AgentModels.kt     Wire models (mirrors MoMoAgentClient)
│   └── PairingStore.kt    Keystore-backed credential storage
└── ui/
    ├── AppViewModel.kt    Pairing and conversation state
    ├── ChatScreen.kt      Conversation and composer
    ├── MoMoApp.kt         Screen routing
    ├── PairingScreen.kt   Scan or paste a pairing code
    ├── QrScanner.kt       CameraX + ML Kit QR scanner
    └── Theme.kt           Brand palette
```

The wire contract is owned by `Packages/MoMoAgentAgentClient`. Do not add a new
server route for Android without updating the Swift client, the Mac access
allowlist, and this app together.

## License

AGPL-3.0-only, matching the rest of the repository.
