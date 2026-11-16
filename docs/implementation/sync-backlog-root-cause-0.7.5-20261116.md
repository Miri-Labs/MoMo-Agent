# Sync backlog root-cause repair — 0.7.5

## Structural root causes of multi-hour recording backlog

1. **iPhone `receipt_outbox` head-of-line deadlock (`PhoneReceiveCoordinator`):**
   - Newly committed chunks appended receipts to the tail of `receipt_outbox` without immediate dispatch, stranding fresh receipts behind thousands of unacknowledged historical receipts (`2,491` for the active Watch, `6,016` total).
   - Automatic recovery set `replayReceiptSweep = true` every cycle and `receiptCursor` lived only in memory. Each background wake or recovery sweep cleared deduplication from `storage_sequence = 0`, filled WatchConnectivity's `16 KiB` control budget with the oldest single-item `ControlMessage.receipt` payloads, hit `.deferred`, and returned early without advancing to newer receipts—while also starving `ReconcileResponse` (`~6.5 KiB`) out of the `16 KiB` budget (`pendingReconcileResponseCountsBySource = 12`).
2. **Single-item control acknowledgement bottleneck (`WatchRuntime` & `ControlMessage`):**
   - Both `Receipt` (Phone -> Watch) and `ReceiptApplied` (Watch -> Phone) traveled one chunk per message, and Watch background `connectivityGrant` capped `controlBatch` at `count = 1`, unable to keep pace with 60 chunks/hour.
3. **`LocalSync` lacked metadata reconciliation (`LocalSyncServer` / `LocalSyncClient`):**
   - `LocalSync` exposed only `/v1/ping`, `/v1/chunks`, and `/v1/receipts-applied`. Clearing `2,491` chunks already stored on the phone still required reading and HTTP-uploading every audio file from Watch Flash over Wi-Fi just to obtain its `Receipt`.

## Changes

- **Removed `freshFileCursor` queue-jumping (`WatchRuntime.swift`):** Restored sequential `fileCursor` progression now that receipt and reconciliation bottlenecks are fixed at the source.
- **Batched `ReceiptBatch` & `ReceiptAppliedBatch` (`ControlMessages.swift`, `RecordingStore.swift`, `ArchiveStore.swift`, `PhoneReceiveCoordinator.swift`, `WatchRuntime.swift`):**
  - Added deterministic `ReceiptBatch` and `ReceiptAppliedBatch` (`ReceiptBatchLimits.maximumItems = 12`, `<= 6.5 KiB` encoded, leaving `>= 9.8 KiB` for a concurrent full 16-item `ReconcileResponse` inside the `16 KiB` control budget) while preserving single-item `.receipt` / `.receiptApplied` wire format when `count == 1`.
  - `RecordingStore.markControlPreserved` marks all constituent `ReceiptAppliedBatch` items delivered in one SQLite transaction.
  - Both iPhone and Watch reserve `>= 10 KiB` of background `transferUserInfo` budget (`outstandingControlBytes <= 6 KiB` gate on background receipt batches) so `ReconcileRequest` and `ReconcileResponse` never stall, while allowing paced single-in-flight interactive batch delivery when reachable.
- **Immediate receipt dispatch & wrap-once sweep cursor (`ArchiveStore.swift`, `PhoneReceiveCoordinator.swift`):**
  - `commitInboxItemForCoordinator` surfaces both newly `.accepted` and `.duplicate` retransmitted chunk IDs (`AcceptedChunkID`), and `reconcile()` immediately dispatches `urgentReceiptControlMessages` ahead of historical backlog.
  - `submitReceiptPage` advances `receiptCursor` forward across pages without resetting to `0` on deferral, completing a full wrap-once cycle before clearing `replayReceiptSweep`.
- **`LocalSync` `POST /v1/reconcile` metadata fast-path (`LocalSyncServer.swift`, `LocalSyncClient.swift`, `PhoneComposition.swift`, `WatchRuntime.swift`):**
  - Added `/v1/reconcile` handler and client call. `WatchRuntime` now runs `reconcileLocalBulk` before `uploadLocalBulkPage`, acknowledging already-stored chunks and batch-posting `receiptsApplied` over Wi-Fi with zero audio re-upload, then uploading only genuinely missing chunks (gracefully falling back on `404` for older peers).

## Validation and delivery

- Passed all `MoMoContractsTests`, `MoMoLinkTests`, `MoMoRecordingTests`, `LocalSyncIntegrationTests`, and `ReceiptPagingTests` cases—including new regression tests verifying 12-item `ReceiptBatch` / `ReceiptAppliedBatch` deterministic identity and `<= 6_800`-byte wire ceiling (leaving `>= 9.5 KiB` inside the `16 KiB` control budget), single-transaction `markControlPreserved(.receiptAppliedBatch)` delivery updates, urgent receipt packing, and `LocalSync` `/v1/reconcile` recovering stored receipts without re-uploading audio bytes.
- Built signed Release products from `fbbf2109`, version **0.7.5** (internal build **120**). Phone and embedded/standalone Watch bundles passed all 29 `verify-release-bundle.py --variant local-upgrade` checks and deep `codesign` verification; embedded and standalone `MoMoAgentWatch` SHA-256 digests matched (`9c9e124b6c4ec9fd58ca7d2e807d88c0cd03c7792dd33e058130e19dd14eb5b3`).
- Built, embedded runtime, signed, and offline-verified Mac Release **0.7.5** (`120`) via `verify-mac-runtime.py`; installed and launched `/Applications/MoMo Agent.app` (`0.7.5` / `120`) with unchanged `connection.json` and `api-key` identity hashes.
- Installed **0.7.5** (`120`) in-place onto both physical `西兰花儿的iPhone` (`00008150-000A31AA1447801C`) and physical `西兰花的Apple Watch` (`00008301-1895081201B8202E`), independently verified via `devicectl device info apps`. The iPhone app launched on device; Watch remote launch returned `CoreDeviceError 4000` while docked, so sustained dual-device runtime drain was not observed during this run.
- Removed this task's `Packages/MoMoAgentKit/.build`, `DerivedData-iOS`, `Packages-iOS`, `DerivedData-Mac`, `Packages-Mac`, default Xcode `DerivedData/MoMoAgent-*`, superseded `0.7.4` verified bundles, and release staging archive after upload; retained the current `0.7.5` verified bundles and compact validation logs in `tmp_agent_output/sync-backlog-0.7.5-20261116/`.

