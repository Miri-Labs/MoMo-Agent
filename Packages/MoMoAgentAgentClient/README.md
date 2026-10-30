# Agent transport

`MoMoAgentClient` owns the existing JSON and SSE contracts. `AgentTransport.open`
may return an alternate byte stream, or nil **before dispatch** to choose HTTPS.
An error after dispatch is surfaced to the durable task journal; it never causes
an automatic replay of a write. Operation IDs, run IDs and event sequence numbers
are unchanged across transports.

`MoMoAgentRTC` implements the optional data path with a reliable, ordered WebRTC
DataChannel. HTTPS remains the authenticated signaling and fallback path. ICE
configuration uses standard STUN/TURN URLs and credentials without provider SDKs.
Suspending the transport cancels subscriptions, not remote Agent execution.

Native dependency: [stasel/WebRTC 155.0.0](https://github.com/stasel/WebRTC/tree/155.0.0),
a distribution of Google libwebrtc M155. The binary SHA-256 pinned by its manifest
is `cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`.
Its BSD notices ship in `Apps/iPhoneApp/Resources/WebRTC-LICENSE.txt`.
The Mac access adapter uses separately locked `aiortc==1.15.0` (BSD-3-Clause);
it does not import the Agent or a model provider SDK.

`momo-rtc-probe PRIVATE_FIXTURE direct|relay|fallback|revoke` exercises native
interoperability. The fixture contains `{ "connection": ..., "credential": ... }`
and should be mode 0600. See `Tests/AgentRuntime/test_webrtc.py` for the isolated
backend, paired grant and local TURN test setup.
