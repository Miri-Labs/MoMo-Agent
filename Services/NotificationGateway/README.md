# MoMo Agent notification gateway

This is an operator-deployed APNs relay, not an Agent, chat server, or a user onboarding step. The Mac retains the conversation and persistent per-device outbox. The gateway accepts only opaque locators and three fixed notification kinds; it never receives recording/health text. The Apple private key stays on this server. A user only enables notifications in the paired iPhone's Settings → Notifications.

## Private deployment

Use Python 3.11+ and this directory's independent `uv.lock` (`uv sync --locked`). Do not add dependencies to the Hermes environment.

Create a mode `0600` JSON config outside the repository:

```json
{
  "database": "/private/momo-push/gateway.sqlite",
  "port": 8870,
  "topic": "com.momoagent.ios",
  "environment": "development",
  "team_id": "YOURTEAMID",
  "key_id": "YOURKEY_ID",
  "key_path": "/private/momo-push/AuthKey.p8"
}
```

The key file also requires mode `0600`. Team/Key IDs must be the real ten-character Apple values. The config check validates the P-256 key and HTTP/2 dependencies; it does **not** prove Apple credentials were accepted:

```sh
uv run --locked gateway.py --config /private/momo-push/config.json --check
```

Run behind your authenticated deployment's TLS reverse proxy (for example Caddy `push.example.com { reverse_proxy 127.0.0.1:8870 }`). The program binds loopback only. Use a service supervisor to restart `uv run --locked gateway.py --config /private/momo-push/config.json`. Do not enable request-body or Authorization logging; the app disables access logs. Back up the SQLite file with a consistent SQLite backup and restrict access to its directory.

Provision one revocable credential per actual Mac `connection.json` instance ID. Do not use a single credential shared by all users:

```sh
umask 077
uv run --locked gateway.py --config /private/momo-push/config.json --issue-instance ACTUAL-INSTANCE-UUID > /private/momo-push/instance-credential
```

Securely provision that credential to the matching Mac's private Agent directory, as `push-gateway.json` (mode `0600`):

```json
{"url":"https://push.example.com","credential":"THE_GENERATED_INSTANCE_CREDENTIAL","environment":"development","topic":"com.momoagent.ios"}
```

Restart that Mac runtime after changing the private configuration. The Mac uses the system proxy environment already provided by its runtime and respects `NO_PROXY`. Never bundle this file or the `.p8` key in an app. This limited Beta requires an administrator to provision the gateway and per-instance credential once; no public self-service enrollment/account system is included.

The Beta build's `MOMO_PUSH_ENVIRONMENT` / `aps-environment`, signed profile, Mac configuration, and gateway must agree. Current Beta configuration is **development**, so the gateway uses Apple's sandbox. Before distribution, an operator must switch the Beta build setting and deployment config together to **production** and verify the actual signed entitlements/profile. The formal app uses `com.momoagent.ios`; Beta uses `com.momoagent.ios.beta`. Select the same topic in both configs. Omitting the Mac topic preserves the previous Beta default. For personal-team local installation only, build with `MOMO_PHONE_ENTITLEMENTS=Apps/iPhoneApp/Resources/MoMoAgentLocal.entitlements MOMO_PUSH_ENVIRONMENT=disabled`; that package cannot receive APNs. Paid-team release builds retain the normal APNs entitlement.

Revoke a gateway instance immediately:

```sh
uv run --locked gateway.py --config /private/momo-push/config.json --revoke-instance ACTUAL-INSTANCE-UUID
```

Reissuing rotates its credential. Mac pairing revocation stops local sending immediately on the next eligibility check and durably retries the corresponding gateway revoke. An already submitted APNs request cannot be recalled; offline remote revocation is not falsely reported as synchronized.

## Contract and behavior

- Bearer credential is bound to one instance in the gateway SQLite store.
- `GET /v1/status`: configured flag, instance, configured app topic and environment. A valid local provider object alone does not enable the Mac capability; an authenticated, matching gateway response is required.
- `PUT /v1/devices/{uuid}`: token, monotonic revision, registration timestamp, fixed topic/environment. The Mac advances revision per iOS APNs registration callback; network retries reuse its registration ID.
- `DELETE /v1/devices/{uuid}`: revision tombstone, idempotent. A stale PUT cannot resurrect a revoked device.
- `POST /v1/notifications`: `{device_id,revision,payload}`. Payload permits only `v,kind,instance_id,assistant_id,conversation_id,run_id,delivery_id,message_id?,control_id?,execution_generation?`. No arbitrary body, URL, command, token or topic.
- Delivery receipts are keyed by `(instance, delivery_id)`; differing payloads conflict. Accepted receipts can be reread. Retry uses the same APNs ID, including after restart/token rotation. Apple acceptance followed by a crash before persistence can duplicate delivery; this is not an exactly-once guarantee.
- Expired provider JWT refreshes once. HTTP/2 is mandatory. 429 respects delay, 5xx waits at least 15 minutes. Permanent rejection does not retry indefinitely. A stale 410 cannot invalidate a newer registration or poison its delivery retry.
- Each notification event is persisted before delivery. Interim acknowledgements, successful background handoffs and historical backfill do not push. Final model results, final failure and exact approval/clarification generation do.
- Device reads/visible controls suppress pending notifications; no badge is fabricated. APNs `200` is only **accepted**, never read or proven visible on the phone.
- No configuration means `system_push=false`. Missing service never prevents chat. A configured gateway temporarily offline retains events for retry; each event expires after 24 hours.

No real APNs key, deployment, Apple acceptance, lock-screen appearance, or device tap has been validated by unit tests. Those need a signed Beta and an operator-supplied private deployment.
