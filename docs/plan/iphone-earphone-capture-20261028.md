# iPhone 蓝牙耳机录音方案 · 2026-10-28

分支 `blankchenxm/feat/bluetooth-earphone-capture`。让没有 Apple Watch 的用户用 iPhone 加蓝牙耳机持续录音，录音进入与手表录音相同的归档、转写和记忆流程。路由切换的真机实验与数据见[耳机切换实验](../implementation/earphone-route-spike-20261027.md)，实现与验证见[实施记录](../implementation/iphone-earphone-capture-20261029.md)。

## 用户已确认的行为

- **录音设备二选一**：Apple Watch 或蓝牙耳机，默认 Apple Watch，现有用户行为不变。选择耳机后手机才录音。
- **只保存耳机麦克风的音频**：当前输入是蓝牙 HFP 时保存；有其他 App 播放声音、耳机关机或断开等情况下，iPhone 麦克风继续运行以保持后台录音会话，但样本全部丢弃。
- **有外部音频就切回高音质**：音乐、视频等任何其他 App 的声音开始播放时，停止耳机录音并切回 A2DP；声音停止 1 秒后切到 HFP 开始录音。
- **自动开始**：选择耳机后，App 每次回到前台自动开始录音（iOS 只允许前台开始录音）；用户手动停止后不自动恢复，直到再次点“开始录音”。
- 进入 HFP 后耳机按键无法恢复播放，用户接受；恢复播放靠屏幕、Siri 或以后的语音指令。

## 实验结论（摘要）

- iOS 第三方蓝牙耳机只有 A2DP（无麦克风）与 HFP（双向、电话音质）。OpenMove HFP 输入为 16 kHz 单声道。
- 后台切换只有“先停引擎、停用会话，再改 category、重新激活”（deactivateFirst）可行：双向约 0.8 秒，切回后输出为 A2DP。直接改 category 在后台被拒（`'!int'`），只改 preferred input 时输出停在 HFP。
- 耳机关机时路由在 0.3 秒内落到内置麦克风，重新开机 0.4 秒内回到 HFP。

## 架构

### 复用手表的录音模块

`MoMoRecording` 没有平台限制，手机直接使用：

- `AudioCaptureEngine` 采集，`CaptureEncoder` 转为与手表相同的 60 秒、16 kHz 单声道 AAC 分段。
- `RecordingStore` 作为手机本机的录音账本，目录 `Application Support/EarphoneCapture/`。分段先封口入账，交付归档并确认收据后才清理，进程退出也不丢已封口的音频。
- 会话 / epoch 语义与手表一致：一次“开始”是一个 session；每段耳机录音是一个 epoch。外部音频开始播放时以 `paused` 结束 epoch，路由丢失或来电以 `interrupted` 记录，用户停止以 `stopped` 结束。

### 本机交付，不经过 WatchConnectivity

新增本机交付环节，在同一进程内把账本里的内容交给 `ArchiveStore`：

1. 封口分段：复制原件 → `archive.inbox.preserve` → `archive.commitReceivedChunk` → 用返回的收据调用账本 `applyReceipt` 与归档 `applyReceipt`，最后 `cleanupAcknowledgedChunks`。两侧收据都落地，归档的自动清理规则与手表录音相同，也不会留下等待手表确认的收据。
2. 采集事件：账本 `controlBatch(.capture)` → `receiveEpochEnd` / `receiveEpochInterruption` / `receiveMark` → `markControlPreserved`。
3. 删除：用户删除耳机会话时，归档的待删除记录由本机账本直接完成并确认（`prepareDeletion` → 停止该会话的采集 → `completeDeletionAfterCaptureStopped` → 归档确认），不发给手表。
4. 每次交付后通知转写调度，与收到手表录音时相同。

身份：手机的 `device-id` 同时是来源设备与接收设备；账本绑定该设备与本机资料库。`SourceKind` 新增 `phone`，与手表会话区分，手表状态查询不会误取耳机会话。旧版本打开含 `phone` 的资料库会解析失败，降级安装需注意。

### 路由与采集

- 会话：`.playAndRecord` + `.mixWithOthers` + `.defaultToSpeaker`；录音时加 `.allowBluetoothHFP` 并优先 HFP 输入，有外部音频时改为 `.allowBluetoothA2DP` 并优先内置麦克风。切换一律走 deactivateFirst。
- 检测：每 0.25 秒读取 `isOtherAudioPlaying` / `secondaryAudioShouldBeSilencedHint`，并监听静音提示通知；静音持续 1 秒才切到耳机。
- 输入门：沿用手表的线程安全门模式。只有“当前输入是蓝牙 HFP 且未被打断”时允许写入；路由通知先同步关门，采集流随即以 `unexpectedInputRoute` 结束并记为中断，不会把内置麦克风的样本写进耳机分段。
- 保活：不保存时用同一个 `AudioCaptureEngine` 采集内置麦克风并直接丢弃，使后台录音会话持续存在，以便耳机回来或外部音频停止时在后台重新开始。
- 打断：来电、Siri 等打断开始时结束当前 epoch；打断结束后按当前路由恢复。媒体服务重置后重建会话。

### 与 App 内其他音频的协调

聊天语音输入（`ChatVoiceInput` / `ChatMicrophoneRecording`）与录音回放（`AudioPlaybackController`）会改写或停用同一个音频会话。二者开始前先暂停耳机录音（结束当前 epoch、停引擎），录音器或播放器释放会话后再恢复，避免互相破坏。

### 设置与界面

- 偏好沿用 `PhoneSpeechSettings` 的 `@Observable` + `UserDefaults` 模式：录音设备（手表 / 耳机）与“用户已手动停止”。
- 设置「转录与储存」新增「录音设备」，选择耳机时显示 iOS 当前连接的耳机名称；App 不能自行配对或连接耳机，未连接时提示到系统蓝牙设置连接。
- 选择耳机后，聊天页 MoMo 右下角小标与转录页状态卡片改为耳机状态（耳机图标，绿：录音中；黄：播放中暂停、耳机未连接或已停止；红：录音失败需处理），卡片提供开始 / 停止。手表相关界面在选择手表时保持不变。

### 工程配置

- iPhone target 增加 `MoMoRecording` 依赖。
- `UIBackgroundModes` 增加 `audio`。
- 麦克风用途说明补充耳机录音。
- 工程用 XcodeGen 2.46.0 重新生成。

## 不在本次范围

- 无耳机时用手机麦克风录音（以后作为可选开关另议）。
- 说话人区分、唤醒词、ASR 模型更换、LLM 纠错（各自单独分支）。
- 语音指令控制其他 App 播放。

## 验证

- 包测试：本机交付（分段入档、收据两侧落地、epoch 结束 / 中断、删除确认）用 `PCM16SegmentWriter` 生成的分段覆盖。
- 真机（iPhone 17 Pro Max + OpenMove，个人团队签名，仅本机 `Config/Local.xcconfig` 覆盖 Bundle ID 与权限文件）：
  - 前台自动开始，锁屏后台持续录音。
  - 播放 / 暂停外部音频的双向切换，切回后音质正常。
  - 耳机关机期间不产生保存的录音。
  - 来电后恢复，Siri 唤起。
  - 锁屏挂机 30 分钟以上不被挂起。
  - 录音进入转录页并完成转写。
  - 语音输入与回放前后耳机录音能暂停和恢复。
  - 删除耳机会话。
