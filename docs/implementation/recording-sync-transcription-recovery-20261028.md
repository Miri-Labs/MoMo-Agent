# Watch 录音同步与后台转录卡死根因修复（2026-10-28）

## 1. 现象与现场取证

在物理设备对（`测试 iPhone` `<IPHONE_UDID>` 与 `测试 Apple Watch` `<WATCH_UDID>`）拉取 `archive.sqlite` 与 `recording.sqlite` 后，定位到两处相互独立的死锁：

1. **后台/前台转录进度卡在 98.7%（Batch `5072A35B-8BEA-4CD0-99F2-BB47F2EBA7BF`，Epoch `AA395CEB-F3A2-4925-BF5C-13DB4F283CFB`）**：
   - `AA395CEB` 共收到 69 个分片（`0..66,240,000` 帧，69 分钟），但 `analysis_epochs.checkpoint` 卡在 `45,534,912`（约 47.43 分钟），剩余 21.57 分钟音频无法进入 VAD 切片与 ASR 转录，`finishTranscriptionBatch` 持续抛出 `TranscriptionBatchError.incomplete`。
2. **Watch ↔ iPhone 对账与回执（Receipt）死锁（Session `D77B642B-B47F-4D58-97BA-7EC5F0BD99A6` 积压 876 个分片 / 561MB）**：
   - iPhone 已完整收到并入库 `D77B642B` 的全部 1,012 个分片，但其中 876 个分片（序号 `128..1011`）的 `receipt_applied = 0`；iPhone 侧 `reconcile_requests` 中最新响应 `879F1AA1`（9,010 字节）长期处于 `pending = 1`。
   - Watch 侧 `chunks` 中这 876 个分片全部处于 `state = 'ready'` 且全部被写入 `reconciliation_receipt_holds`（876 行），同时 `reconciliation_requests` 累积了 1,426 次对账请求。

---

## 2. 根因分析

### 2.1 转录 VAD 强制冲刷 + 尾部静默与分片窗口缓存死锁

1. **`VADContinuation.lastFlushWasForced` 在长静默期永不复位**：
   - 在 `AA395CEB` 从 `45,342,912` 开始的分析轮次中，输入为 `[Chunk 47, 48, 49]`（`45,120,000..48,000,000`）。
   - 连续语音在 `45,534,912` 处达到 16 秒（`256,000` 帧）上限，触发 `detector.flush()` 强制切段，`lastFlushWasForced = true`。
   - 紧接着 `45,534,912..48,000,000` 是长达 154 秒的静默，`detector.speechDetected == false` 且 `detector.drain()` 返回空数组，导致 `lastFlushWasForced` 永远停留在 `true`。
   - `SpeechEngine` 在 `boundary == .open` 下因 `quiet == false` 将 `quietEnd` 退回 `input.start`，使该轮 `checkpoint` 仅推进到 `45,534,912`，并以 `waitingForMoreAudio = true` 提交。
2. **`claimEpochAnalysis` 的 `tailInputs` 去重窗口短于已缓存的多分片跨度**：
   - 上述轮次在 `45,534,912` 处缓存了 `tailInputs = hash([Chunk 47, 48, 49])`（覆盖至 `48,000,000`）。
   - 下一轮 `claimEpochAnalysis` 从 `start = 45,534,912` 计算 `through = start + 1,920,000 = 47,454,912 < 48,000,000`，`contiguousInputs` 仍然只选出 `[Chunk 47, 48, 49]`，完全看不到后续到达的 `Chunk 50..68`（`48,000,000..66,240,000`）。
   - 因 `identity([Chunk 47, 48, 49]) == previous` 且 `boundary == .open`，`claimEpochAnalysis` 判定“无新音频”而直接跳过该 Epoch，形成永久死锁。

### 2.2 Watch ↔ iPhone 对账与回执（Receipt）双向互锁

1. **在途 `.ready` 分片收到 `.unknown` 后误入 `reconciliation_receipt_holds`**：
   - 当分片 `128..1011` 仍在 `WCSession.transferFile` 队列中传输时，Watch 发起对账请求；iPhone 尚未收到文件，如实回复 `.unknown`。
   - Watch 在 `applyReconciliationResponse` 中将 `.unknown` 与 `.missing` 合并处理，调用了 `holdReceipts(chunkID)`，把从未确认过的在途 `.ready` 分片写入 `reconciliation_receipt_holds`。
   - 几秒后文件到达 iPhone，iPhone 立即发回 `ControlMessage.receipt`；Watch 在 `applyReceipt` 中检查到 `reconciliation_receipt_holds` 存在该分片，抛出 `RecordingError.receiptNeedsReconciliation`，拒绝直接应用回执，转而要求必须通过 `ReconcileResponse` 解除屏障。
2. **iPhone 端 460B `Receipt` 饿死 9KB `ReconcileResponse`**：
   - Watch Connectivity 控制通道预算上限为 32 条 / `16,384` 字节。
   - iPhone `receipt_outbox` 中有 876 条未确认 `Receipt`（每条约 460 字节），占满 31 个槽位（`14,260` 字节）。
   - 每当 1 条 `Receipt` 传输完成腾出 1 个槽位时，`reconcile()` 先尝试 `submitResponse(879F1AA1)`（64 条对账结果，9,010 字节），但 `14,260 + 9,010 = 23,270 > 16,384`，返回 `.deferred`；随后 `reconcile()` 立即执行 `submitReceiptPage`，用另一条 460 字节的 `Receipt` 填满刚腾出的槽位，导致 `ReconcileResponse` 永远无法进入后台通道。
   - 同时，即便 `ReconcileResponse` 通过 `sendMessage` 交互通道送达 Watch，iPhone 在收到 `.controlTransportFinished` 确认时也未调用 `markReconcileResponseSubmitted`。
3. **Watch 端 `controlCursors[.receipt]` SQLite 游标未归零与控制通道配额独占**：
   - Watch 在生成新 `ReceiptApplied` 时将内存 `controlCursors[.receipt]` 设为 `nil`，但未将 `control_positions` 表中的持久化游标归零，下一次读取时再次从旧游标恢复。
   - 非交互周期下单类控制消息可一次性占满 32 个控制槽位，挤压其他控制消息与 `ReconcileRequest`。

---

## 3. 修复方案

1. **VAD 强制冲刷后的静默恢复**（[`VADContinuation.swift`](../../Packages/MoMoAgentKit/Sources/MoMoSpeech/Analysis/VADContinuation.swift)、[`SpeechEngine.swift`](../../Packages/MoMoAgentKit/Sources/MoMoSpeech/API/SpeechEngine.swift)）：
   - 在 `VADContinuation` 中跟踪连续静默帧 `quietFrames` 与未排空语音下界 `undrainedSpeechFloor`。当 `!detector.speechDetected` 连续达到 `32,000` 帧（2 秒，即 Silero VAD 桥接窗口上限）时，自动复位 `lastFlushWasForced = false` 与 `undrainedSpeechFloor = nil`。
   - 在 `SpeechEngine` 计算开放边界 `quietEnd` 时，基于 `position - pendingFrames` 并按未归属语音区间和 `undrainedSpeechFloor` 精确截断，不再因历史强制冲刷将 `quietEnd` 退回 `input.start`。
2. **跨多分片缓存尾部的开放分析扩展**（[`EpochAnalysis.swift`](../../Packages/MoMoAgentKit/Sources/MoMoArchive/EpochAnalysis.swift)）：
   - 当 `boundary == .open` 且选出的 `inputs` 哈希与已缓存 `tailInputs` 相同时，若 `last.envelope.manifest.frames.end` 之后存在新到达的连续分片，自动将 `through` 扩展至 `last.envelope.manifest.frames.end + step`，确保新分片立即被纳入分析。
3. **区分 `.unknown` 与 `.missing` 的回执屏障语义**（[`RecordingReconciliation.swift`](../../Packages/MoMoAgentKit/Sources/MoMoRecording/Ledger/RecordingReconciliation.swift)）：
   - `.unknown` 仅对已处于非 `.ready` 状态或已持久化过回执的分片调用 `holdReceipts`；首次在途传输的 `.ready` 分片收到 `.unknown` 只调度文件重传，不锁死后续到达的直接 `Receipt`。
4. **控制通道防饿死与双通道投递确认**（[`WatchConnectivityTransport.swift`](../../Packages/MoMoAgentKit/Sources/MoMoLink/WatchConnectivity/WatchConnectivityTransport.swift)、[`PhoneReceiveCoordinator.swift`](../../Apps/iPhoneApp/Application/Receiving/PhoneReceiveCoordinator.swift)、[`WatchRuntime.swift`](../../Apps/WatchApp/Application/WatchRuntime.swift)）：
   - `PhoneReceiveCoordinator`：当 `pendingReconcileResponses` 因控制通道字节预算返回 `.deferred` 时，暂停本轮 `submitReceiptPage` 补位，优先腾出预算给 `ReconcileResponse`；当 `.controlTransportFinished` 确认 `ReconcileResponse` 已送达时立即标记 `markReconcileResponseSubmitted`；`submitReceiptPage` 感知交互通道准入结果，避免在背景队列满时卡在首条回执。
   - `WatchRuntime`：新生成 `ReceiptApplied` 时同步持久化 `saveControlPosition(0, kind: .receipt)`；非交互模式下限制每类控制消息单次最多提交 8 条，保留控制预算给其他队列与对账请求。

---

## 4. 回归测试与真机验证

- **新增单元与集成回归测试**：
  - `RealSpeechTests.forcedFlushFollowedByLongSilenceStillAdvancesOpenCheckpoint`（[`SpeechTests.swift`](../../Packages/MoMoAgentKit/Tests/MoMoSpeechTests/SpeechTests.swift)）
  - `TranscriptionBatchTests.openAnalysisExtendsPastMemoizedMultiChunkTailToClaimNewlyArrivedChunks`（[`TranscriptionBatchTests.swift`](../../Packages/MoMoAgentKit/Tests/MoMoArchiveTests/TranscriptionBatchTests.swift)）
  - `RecordingReconciliationTests.unknownForInflightReadyChunkDoesNotBlockSubsequentDirectReceipt`（[`RecordingReconciliationTests.swift`](../../Packages/MoMoAgentKit/Tests/MoMoRecordingTests/RecordingReconciliationTests.swift)）
  - `PhoneReceiveStatusTests.testConfirmedInteractiveResponseMarksResponseSubmittedAndAvoidsReceiptStarvation`（[`PhoneReceiveStatusTests.swift`](../../Tests/iPhoneIntegrationTests/PhoneReceiveStatusTests.swift)）
- **真机实测结果（`1.39.1` / Build `163`）**：
  - 安装并启动 iPhone 端 `1.39.1`（Build `163`）后，拉取真机 `archive.sqlite` 核实：
    - `AA395CEB-F3A2-4925-BF5C-13DB4F283CFB` 的 `checkpoint.sourceFrame` 从 `45,534,912` 推进至 `66,240,000`（100% 覆盖）；
    - 新分析出的 23 个语音窗口全部完成 ASR 转录（`analysis_windows` 中 `complete = 15,138`，0 pending / 0 failed）；
    - 卡死 17 小时的后台转录批次 `5072A35B-8BEA-4CD0-99F2-BB47F2EBA7BF` 状态变为 `completed|completed`。
