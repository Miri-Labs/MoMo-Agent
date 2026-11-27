#!/usr/bin/env python3
"""Fast static architecture guardrail checks derived from CODING_STANDARDS.md.

Runs in <100ms with zero external dependencies. Intended for local verification and CI.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
FAILURES: list[str] = []


def read(rel: str) -> str:
    path = ROOT / rel
    if not path.exists():
        FAILURES.append(f"Missing expected file: {rel}")
        return ""
    return path.read_text(encoding="utf-8")


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def main() -> int:
    # 1. HTTP/1.1 keep-alive & explicit Content-Length on 416 in context_server.py
    ctx = read("Apps/MacApp/Context/context_server.py")
    check('protocol_version = "HTTP/1.1"' in ctx,
          "context_server.py: Handler must set protocol_version = 'HTTP/1.1' for keep-alive")
    m416 = re.search(r"send_response\(416\)[\s\S]{0,240}end_headers\(\)", ctx)
    check(bool(m416 and "Content-Length" in m416.group(0)),
          "context_server.py: HTTP 416 response must send explicit Content-Length for HTTP/1.1 keep-alive")

    # 2. Voiceprint schema init caching (avoid per-request executescript)
    vp = read("Apps/MacApp/Context/voiceprint_store.py")
    check("_VOICEPRINT_SCHEMA_READY_PATHS" in vp,
          "voiceprint_store.py: init_voiceprint_schema must cache schema-ready DB paths")

    # 3. No per-chunk os.fsync inside normal batch/single ingestion hot path
    pipe = read("Apps/MacApp/Context/mac_audio_pipeline.py")
    for fn_name in ("def ingest_audio_chunk(", "def ingest_audio_chunks_batch("):
        idx = pipe.find(fn_name)
        check(idx != -1, f"mac_audio_pipeline.py: missing {fn_name}")
        if idx != -1:
            next_def = pipe.find("\n    def ", idx + len(fn_name))
            body = pipe[idx : next_def if next_def != -1 else len(pipe)]
            check("os.fsync(" not in body,
                  f"mac_audio_pipeline.py: {fn_name} must not call os.fsync() on normal ingestion hot path")

    # 4. Idempotency-Key on idempotent audio/speech POST endpoints + bounded status timeouts
    speech_client = read("Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/SpeechBackendClient.swift")
    for fn_sig in (
        "func uploadAudioChunk(",
        "func uploadAudioChunksBatch(",
        "func audioChunkBatchStatus(",
        "func requestRetranscribe(",
        "func dictateAudio(",
        "func rematchVoiceprints(",
    ):
        idx = speech_client.find(fn_sig)
        check(idx != -1, f"SpeechBackendClient.swift: missing {fn_sig}")
        if idx != -1:
            next_fn = speech_client.find("\n    public func ", idx + len(fn_sig))
            body = speech_client[idx : next_fn if next_fn != -1 else len(speech_client)]
            check('"Idempotency-Key"' in body,
                  f"SpeechBackendClient.swift: {fn_sig} must set Idempotency-Key for safe Tailscale retry")
    m_status = re.search(r"func transcriptionStatus\([\s\S]{0,220}timeout:\s*(\d+)", speech_client)
    check(bool(m_status and int(m_status.group(1)) <= 20),
          "SpeechBackendClient.swift: transcriptionStatus() must specify an explicit timeout <= 20s")

    # 5. EmbeddedTailnetTransport must not retry .timedOut on large bodies (> 64 KB)
    transport = read("Apps/ClientUI/Network/EmbeddedTailnetTransport.swift")
    check("code == .timedOut" in transport and "64 * 1024" in transport,
          "EmbeddedTailnetTransport.swift: must fail fast on .timedOut for bodies > 64 KB")

    # 6. MacAudioUploadStore must skip legacy complete chunks when upload_state IS NULL
    store = read("Packages/MoMoAgentKit/Sources/MoMoArchive/MacAudioUploadStore.swift")
    check("u.upload_state IS NULL AND (j.state IS NULL OR j.state != 'complete')" in store,
          "MacAudioUploadStore.swift: must exclude legacy settled chunks (j.state = 'complete') from auto-backfill")

    # 7. AudioUploadCoordinator adaptive sizing + non-blocking pollTask
    uploader = read("Apps/iPhoneApp/Application/Uploading/AudioUploadCoordinator.swift")
    check("adaptiveMaxChunksPerBatch" in uploader and "downshiftAfterTransportFailure" in uploader,
          "AudioUploadCoordinator.swift: must implement adaptive slow-start and transport-failure downshift")
    m_poll = re.search(r"pollTask = Task[\s\S]{0,3200}?\n        \}\n    \}", uploader)
    check(bool(m_poll), "AudioUploadCoordinator.swift: could not inspect pollTask")
    if m_poll:
        poll_body = m_poll.group(0)
        # Disallow direct synchronous await on syncRemoteTranscriptsFromMac inside pollTask while loop
        lines = [ln.strip() for ln in poll_body.splitlines()]
        sync_direct_await = any(
            ln == "await self.syncRemoteTranscriptsFromMac()" for ln in lines
        )
        check(not sync_direct_await,
              "AudioUploadCoordinator.swift: pollTask must not synchronously await syncRemoteTranscriptsFromMac()")

    # 8. Audio route observability in BOTH TailnetDiagnostics.swift and access_server.py
    diag = read("Apps/ClientUI/Network/TailnetDiagnostics.swift")
    access = read("Apps/MacApp/Access/access_server.py")
    for route in (
        "/context/v1/audio/chunks",
        "/context/v1/audio/chunks/batch",
        "/context/v1/audio/chunks/batch-status",
        "/context/v1/audio/stream",
        "/context/v1/transcription/status",
    ):
        check(f'"{route}"' in diag,
              f"TailnetDiagnostics.swift: missing route category for {route}")
        check(f"'{route}'" in access or f'"{route}"' in access,
              f"access_server.py: missing phone-link.log route for {route}")

    # 9. Retention reclaim must require verified upload_state = 'uploaded' + remote_sha256 + j.state = 'complete'
    retention = read("Packages/MoMoAgentKit/Sources/MoMoArchive/Retention.swift")
    check("func pruneUploadedMacAudio(" in retention
          and "u.upload_state = 'uploaded'" in retention
          and "u.remote_sha256 IS NOT NULL" in retention
          and "j.state = 'complete'" in retention,
          "Retention.swift: pruneUploadedMacAudio must require verified upload_state, remote_sha256, and settled transcription")

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} architecture invariant(s) violated:", file=sys.stderr)
        for item in FAILURES:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print("PASS: all MoMo Agent architecture invariants verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
