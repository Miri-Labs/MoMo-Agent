# iPhone 到 Mac 转录文本同步修复（2026-10-27）

## 现象与根因

1. **未完成转写或静音录音阻断全部历史转录同步**：
   - [`PhoneContextSync.uploadSources()`](../../Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift) 按 `recordingsPage`（时间倒序）先遍历全部录音执行 `stage(recording)`，全部完成后才进入 `deliver(source)` 循环。
   - 当最新录音刚从手表传到手机、尚处于 `transcriptVersion == 0`（无 `transcript_versions` 行），或某条历史录音一直无有效语音（如 `4B6A22EF`，`transcript_version == 0`），`stage(recording)` 调用 `archive.transcriptSnapshot` 会抛出 `ArchiveError.missingTranscript`。
   - `uploadSources()` 未捕获该异常，导致整个同步流程在进入 `deliver(source)` 前直接中断，已暂存（staged）的转录也永远无法送达 Mac。
2. **仅识别出标点且被丢弃的空段落版本（`spans == []`）**：
   - 当某段录音首个转写窗口仅包含标点并被过滤时，`transcript_version` 递增为 `1` 但 `spans` 为空；若直接作为新来源上传，会在 Mac 侧生成 0 字符空记录。
3. **增量转写与后台/锁屏场景未触发或过早中断同步**：
   - [`PhoneRuntime`](../../Apps/iPhoneApp/Bootstrap/PhoneRuntime.swift) 在转写窗口推进（`completedNewWindows`）或后台延迟展示模式（`libraryPresentationDeferred == true`）以及 `start()` 完成收件箱对账后，未触发 `remoteAgent.sourcesChanged()`。
   - [`PhoneRemoteAgent`](../../Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift) 的 `sourcesChanged()` 仅在 `active == true` 时执行，且未持有 `PhoneConnectivityTask` 后台执行时间；同时 `leavingForeground()` 在切入 `.inactive` 时立即调用 `context?.background()` 取消正在进行的上传任务（`inFlight?.cancel()`）。

## 修复方案

- **[`Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift`](../../Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift)**：
  - `uploadSources()` 仅暂存 `recording.transcriptVersion > 0` 的录音；对从未同步过且 `document.spans.isEmpty` 的初始空版本跳过暂存。
  - 隔离单条录音的暂存与投递异常（保留首个非取消错误并在尝试完其余可投递转录后抛出，401 鉴权错误立即中断），按 `recordedAt` 倒序优先投递最新转录。
  - 拆分 `stopPolling()` 与 `background()`，使短暂 `.inactive` 仅停止定时轮询而不强行取消进行中的 `inFlight` 同步。
- **[`Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift`](../../Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift)**：
  - `replyContinuation` 将 `context?.isSyncing == true` 纳入保活条件，在后台任务到期或完成时再挂起 `context?.background()`。
  - `sourcesChanged()` 通过 `PhoneConnectivityTask.run { await context.refresh() }` 在后台唤醒或锁屏转写完成时保持后台时间完成上传。
- **[`Apps/iPhoneApp/Bootstrap/PhoneRuntime.swift`](../../Apps/iPhoneApp/Bootstrap/PhoneRuntime.swift)**：
  - 在 `start()` 对账完成后、前台增量窗口完成时（`completedNewWindows`）以及后台延迟模式（`libraryPresentationDeferred`）窗口完成或收敛时均触发 `remoteAgent.sourcesChanged()`。
- **仅同步转录文本**：
  - 手机到 Mac 的同步负载（`SourceEnvelope`）仅包含 `spans`（段落 ID、文本、时间戳）及校验哈希，不包含任何原始音频文件。

## 验证证据

- **集成测试**：
  - `xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgent -destination "platform=iOS Simulator,id=AC2B247F-999E-48DA-BC31-A81CF5662EB0" -only-testing:MoMoAgentIntegrationTests/RemoteContextSyncTests test`
  - [`RemoteContextSyncTests`](../../Tests/iPhoneIntegrationTests/RemoteContextSyncTests.swift) 全部 3 项测试通过（含新增回归测试 `testPendingUntranscribedRecordingDoesNotBlockOlderTranscriptDelivery`，同时覆盖最新未转写录音 `transcriptVersion == 0` 与仅标点空段落录音 `transcriptVersion == 1, spans == []` 不阻塞旧转录投递）。
- **Release 产物校验与真机端到端验证**：
  - 版本提升至 `1.36.1` (`152`)，构建 `/Users/syh/Workspace/MoMoAgent-deliveries/main-1.36.1-r152/MoMoAgent.app`。
  - `uv run --no-project python3 Tests/Support/verify-release-bundle.py` 返回 `"status": "passed"`，`codesign --verify --deep --strict` 校验通过。
  - 安装至真机 `测试 iPhone` (`<IPHONE_UDID>`) 并启动 `com.momoagent.ios`。
  - 真机 `MacAgent/context.json` 中全部 10 条已转写录音回执（`receipt`）均更新为 `true`，`lastSourcesSent` 已记录；未转写的无语音录音 `4B6A22EF` 被跳过且未阻塞。
  - Mac 端 `/Users/syh/Library/Application Support/MoMoAgent/Agent/context/context.sqlite` 的 `sources` 表已完整收到全部 10 条转录文本（含 `d77b642b`、`0ee5d27d`、`e0b5c310`、`eb678f56`、`8eb702bb`、`382c1d04`、`f7dfb896`、`d618dd11`、`fc19249e`、`bf438c06`）。
