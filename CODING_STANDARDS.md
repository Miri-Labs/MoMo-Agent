# MoMo Agent Coding Standards & Architecture Invariants

Engineering invariants enforced across Swift (`Apps/`, `Packages/`) and Python (`Apps/MacApp/`). Run `python3 Tests/Support/check-architecture-invariants.py` before opening PRs that touch networking, audio relay, SQLite, or Mac Access/Context servers.

## 1. Tailscale / DERP / Relay Transport

- **HTTP/1.1 Keep-Alive on Mac Context Server**: `BaseHTTPRequestHandler` subclasses serving iPhone traffic (`Apps/MacApp/Context/context_server.py`) must set `protocol_version = "HTTP/1.1"` and emit an explicit `Content-Length` on every response (including `416` and empty error bodies) so persistent connections reuse cleanly over Tailscale/DERP.
- **Idempotency Keys on Safe POSTs**: Every idempotent `POST` crossing Tailscale/Relay (`uploadAudioChunk`, `uploadAudioChunksBatch`, `audioChunkBatchStatus`, `requestRetranscribe`, `dictateAudio`, `rematchVoiceprints`) must set `Idempotency-Key` so `EmbeddedTailnetTransport` can safely absorb cold SOCKS5 `-1000` (`URLError.badURL`) cutoffs without duplicating writes.
- **No Transport-Layer Retry on Large Timed-Out Uploads**: `EmbeddedTailnetTransport.canRetryBeforeResponse` must return `false` for `URLError.timedOut` when request body size exceeds `64 KB`. Repeating a timed-out multi-chunk upload inside transport triples the stall (`3x timeout`) and starves interactive chat/SSE over DERP; surface timeouts immediately so the uploader downshifts batch size.
- **Adaptive Slow-Start & AIMD Batching**: Bulk uploaders (`AudioUploadCoordinator`) must start with a bounded probe (`<= 500 KB`, concurrency `1`), ramp to multi-chunk concurrent batches (`12 chunks / 3.2 MB x 2`) only after measured throughput proves a fast link (`>= 400 KB/s`), and step down immediately to serial single-chunk uploads with inter-chunk breathers on slow links (`< 120 KB/s`) or batch timeouts.
- **Friendly User-Facing Transport Errors**: Map `AgentTransportFailure.isSocketOrLinkFailure` (including CFNetwork SOCKS5 `-1000` / `POSIX EINVAL 22`) to clear localized reconnection text; never leak raw `"错误的 URL"` / `"bad URL"` or `-1022` strings into UI banners.
- **Bounded Status Timeouts**: Health/status polling endpoints (`transcriptionStatus`, `audioChunkBatchStatus`) must specify explicit short timeouts (`<= 20s`), never inheriting 90-second upload defaults.

## 2. SQLite, Storage & Migration Hygiene

- **Cache Schema Initialization**: SQLite stores instantiated per HTTP request (`voiceprint_store.py`, etc.) must cache schema-ready paths in-process (e.g. `_VOICEPRINT_SCHEMA_READY_PATHS`) instead of running DDL (`executescript`) on every request.
- **No Per-Chunk Double `fsync` in Hot Ingestion**: Batch writes into a single SQLite transaction (`ingest_audio_chunks_batch`) and reserve `os.fsync` for corruption repair paths rather than normal HTTP chunk ingestion.
- **No Legacy Historical Backfill on Upgrade**: Adding remote sync/upload tracking (`mac_audio_uploads`) must never automatically enqueue already-settled historical records (`j.state = 'complete'` with `u.upload_state IS NULL`) into the upload queue.
- **Mac-First Audio Reclaim & On-Demand Streaming**: Local iPhone audio reclaim (`ArchiveStore.pruneUploadedMacAudio`) may only remove chunks that have BOTH a verified Mac upload receipt (`upload_state = 'uploaded'` with non-empty `remote_sha256`) AND settled transcription (`j.state = 'complete'`). Reclaimed chunks remain playable via `GET /context/v1/audio/stream?chunk_id=...` into a bounded local LRU cache (`Library/Caches/MoMoAgent/remote-audio-v1`, excluded from backup).

## 3. Async Loops & UI Honesty

- **Never Block Upload Wake-Up on Remote Sync**: Background/foreground polling loops (`AudioUploadCoordinator.pollTask`) must not synchronously `await` slow remote transcript sync ahead of upload retry checks; launch deduplicated transcript sync asynchronously so expired upload backoffs wake immediately.
- **Preserve Errors Across Partial Failures**: In batch upload loops, only clear `lastError = nil` when `hitTransportOutage == false && firstBlockingError == nil`.
- **Honest Sync Indicator**: Show an active spinner only while an upload pass is actually in flight (`isUploading`); when pending work is waiting in backoff or offline, display waiting state and an explicit retry/sync action.

## 4. End-to-End Observability (Privacy-Safe)

- Every hot iPhone ↔ Mac route (`/context/v1/audio/chunks`, `/context/v1/audio/chunks/batch`, `/context/v1/audio/chunks/batch-status`, `/context/v1/audio/stream`, `/context/v1/transcription/status`, conversation routes) must be allowlisted in BOTH:
  - `Apps/ClientUI/Network/TailnetDiagnostics.swift` (`category(_:)`)
  - `Apps/MacApp/Access/access_server.py` (`phone-link.log` `routes`)
- Logs record only static route category, status code, latency, error domain/code, and random `X-MoMo-Connection-Attempt` UUID — never transcript text, audio bytes, IP addresses, or credentials.
