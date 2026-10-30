# 本地转写接入与验证

初次接入：2026-10-14；Core ML 后端：2026-10-17，见 [迁移记录](sensevoice-coreml-20261017.md)。模块为 `Packages/MoMoAgentKit/Sources/MoMoSpeech`。模型文件、校验值、获取脚本和许可证见 [SpeechVendor](../../Native/SpeechVendor/README.md)。

## 调用和状态归属

App 创建一份 `SpeechEngine`，并让前台、后台、重试协调器共享。Speech 内部保留一条识别队列和一条分析队列。识别队列独占选定的 Core ML 或参考 recognizer；VAD 独占分析队列。模型对象在所属队列创建、使用、释放。输入解码完成并释放文件句柄后，才进入单次 ASR。Speech 不依赖 Archive，不修改数据库。

1. Archive 领取 epoch 分析票据，提供从 checkpoint 到当前连续末端的有序原音。票据包含 session、epoch、generation、attempt 和配置指纹。
2. App 将票据转换成 `SpeechAudioInput` 和 `SpeechCheckpoint`，调用 `prepare(inputs:resume:epochClosed:attempt:)`。
3. App 将 windows、analyzedCoverage、noSpeechCoverage 和 checkpoint 在 Archive 的同一事务提交。只有该事务成功，下一轮才使用新 checkpoint。
4. Archive 独立领取 ASR 窗口，提供从 `analysisAnchor` 到上下文末端的全部原音，而不只提供与语音核心相交的文件。
5. App 调用 `transcribe(window:inputs:attempt:)`，再由 Archive 校验 generation、attempt、session 删除状态和输入版本后提交结果。

`SpeechWindow` 同时保存原始采集帧与 16 kHz 模型帧坐标。后者相对 `analysisAnchor`。`sources` 描述上下文与原文件的交集；`replayInputManifestHashes` 则绑定重采样重放经过的全部文件。ID 由这些字段与配置指纹共同计算，转写前重新计算校验。Swift 适配层不按文本相似度删句。

历史分析配置指纹包含三个参考文件的 SHA256、sherpa 源码 commit、ORT 版本、语言、ITN、线程数、VAD 参数、padding、核心上限、分析采样率和窗口规则版本。修改这些值必须使用新的分析任务与结果代次，不能复用旧窗口。Core ML 迁移保留该分析身份，新识别后端的权重、语言、ITN 与解码规则另写入 `recognitionFingerprint`；升级不重跑已完成窗口，详情见迁移记录。

## 连续音频与恢复规则

当前规则为 `silero512-continuous-v1`：

- AVAudioConverter 持续输出 16 kHz、单声道 Float32。一个转换器跨越多个物理文件；文件结束不会添加静音，不会刷新或重置 VAD。输入清单必须在同一 epoch 连续，格式一致，timebase 等于源采样率。缺口直接报错。
- 打开每个原音时校验字节数、SHA256、真实编码格式、解码帧数、采样率和声道。按照清单裁掉 priming / padding，再进行连续重采样。
- Silero 每次只接收 512 帧。默认阈值 0.5、最短语音 250 ms、结束静音 500 ms。跨文件保留未满 512 帧的尾部。
- sherpa 1.13.8 的 `max_speech_duration` 会改变阈值，并不直接产生固定时长切分。本实现将其设为 3600 秒；每累计 16 秒活动语音刷新原生样本缓存，保留 Silero 模型状态。相接的分段合并后，按固定 20 秒核心切分，不让原生样本缓存随全天录音增长。[固定版本实现](https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/sherpa-onnx/csrc/voice-activity-detector.cc)
- 完整 20 秒核心互不重叠，末端不加右 padding，保证后续语音到达后该核心的 ID 不变。短段默认前后各最多 300 ms 静音上下文；相邻静音不足时在中点收缩。
- 安全恢复点必须处于已闭合语音之后，并读足左右 padding、最短语音判定和两帧模型回看所需的静音。默认共 14624 模型帧。一次恢复至少前进 10 秒，避免长静音每不足 1 秒重读文件并计算哈希。
- 正常执行和恢复执行都在相同安全点重置转换器与 VAD。尚未闭合的长语音只发表已经稳定的完整核心，不推进 checkpoint；恢复时从最后安全点重放，窗口 ID 用于幂等落库。
- `epochClosed=true` 才允许给最后不足 512 帧补零以完成 VAD，并立即把检测范围裁回真实音频。重采样长度向下取整；回映源坐标向上取整。闭合 epoch 的不足一个 16 kHz 采样的源尾部计入已分析覆盖，checkpoint 精确到真实源末端。

当前稳定窗口不提供逐字剪裁、说话人分离或情绪决策。`rawJSON`、tokens、timestamps 按原生结果保存；timestamps 是窗口上下文内的模型时间，不能直接当作 session 绝对时间。

## 取消、异常和模型准备

`SpeechAttempt.cancel()` 通过锁立即使票据失效。排队任务、音频解码、每个 VAD 帧、native decode 前后都会检查。已进入 C API decode 或 Core ML prediction 的单次计算不能被安全强制终止，因此取消会等待该次计算返回，再丢弃结果。一次 ASR 最多处理 20 秒核心及两侧最多 300 ms 上下文；后台过期的硬上限仍须在 iPhone 真机测量。

模型加载失败、文件损坏、窗口不兼容和音频缺口均抛出明确错误。没有网络 ASR fallback。Archive 的结果代次检查仍是阻止迟到结果恢复已删除数据的最终边界；只调用取消不够。

模型缺失时，App 应显示“模型未就绪”，保留原音与待处理任务。`SpeechModelBundle.load(from:)` 只读取本地目录；分析首次使用时校验 VAD，识别首次使用时校验选定后端的模型文件 SHA256；VAD 同时检查 native sherpa 和 ORT 版本。应用随包提供已校验模型时，运行时不需要联网下载。

## 早期共享链路验证

在 Apple Silicon Mac 上，使用 Swift 6.2 Command Line Tools 和官方静态 XCFramework，已执行：

| 验证 | 结果 |
| --- | --- |
| `swift build --target MoMoSpeech` | 通过，直接使用 `SherpaOnnxC`，不需自制 C++ 桥 |
| 官方中文样本在早期测试窗口中的 SenseVoice INT8 结果 | 输出“开放时间早上9点至下午5点。”，14 tokens、14 timestamps、保留 raw JSON；当前完整 WAV 的单独结果见下文 |
| 57 秒静音后开始讲话，跨两个 60 秒文件 | 首文件不提前提交尾句；两文件到齐后完整识别，来源绑定两个文件 |
| 相同安全点恢复重放 | 窗口 ID、坐标、输入哈希与 checkpoint 完全一致 |
| 43.75 秒连续真人语音 | live 先发表 1 个完整核心；结束后 3 个窗口；此前核心保持相同 ID，核心范围不重叠 |
| 44.1 kHz / 48 kHz 重采样跨文件 | 拆分与不拆分的输出逐 Float 相同 |
| 44.1 kHz 的非整除源末端 | 闭合 checkpoint 精确到第 200003 源帧，无残余任务死循环 |
| AAC-LC 中文录音解码 | AVAudioFile 实际编码为 24 kbps AAC，再离线识别，正文与官方预期一致 |
| priming / padding 裁剪 | 4000 帧原音减去 256 帧 priming 和 512 帧 padding，3232 个有效采样逐个一致 |
| C decode 开始后取消 | 不返回过期结果；同一执行者的新 attempt 可以继续转写 |
| App Coordinator + Archive + Speech | 真收件、恢复、7 个分析批次、1 个跨文件 ASR 窗口、正文与 JSON/Markdown 保存通过 |

中文预期来源是 sherpa 的 [官方 ITN 示例](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html#with-inverse-text-normalization)，未根据本轮识别结果反写预期。

正式测试位于 `Tests/MoMoSpeechTests/`。早期 CLT 缺少 `Testing` 模块，上表使用直接链接生产模块的 Swift 验证程序执行。证据在本机任务目录 `tmp_agent_output/20261013-momoagent-implementation/speech/`，跨模块证据在 `tmp_agent_output/20261013-momoagent-archive-checks/coordinator-01/`。

2026-10-14 已完成完整 Xcode 27 / Swift 6.4 的正式包测试，Speech 12 项通过；iPhone 17 Pro / iOS 27 模拟器中的跨文件、静音、识别中删除三项 XCTest 也已执行通过。它们不能替代真机和中文质量集验收，最新配置复跑情况见[实施记录](status.md)。

正式包测试可按以下方式运行：

```sh
MOMO_SPEECH_MODEL_DIRECTORY=/absolute/path/to/Models/Speech \
MOMO_TEST_OUTPUT_DIRECTORY=/absolute/path/to/tmp_agent_output/speech-tests \
swift test --package-path Packages/MoMoAgentKit --filter MoMoSpeechTests
```

## 已知中文质量问题：SV-ZH-001

公开 `zh.wav` 的参考文字仍为“开放时间早上9点至下午5点。”，哈希见 [SpeechFixtureMetadata.json](../../Tests/Support/SpeechFixtureMetadata.json)。不根据识别输出修改参考文字。

2026-10-14 模拟器 UI 测试实际保存了“开饭时间早上9点至下午5点。”。归档原音 SHA-256 与官方文件一致，文件没有过期或缺失。真实 VAD 核心为 `[11872, 89472)`，送入 ASR 的范围为 `[7072, 89472)`，采样率 16 kHz。

随后使用同一正式模型与运行时进行串行控制比较：

| 输入 | 自动语言 | 指定中文 |
| --- | --- | --- |
| 完整官方 WAV | “开饭” | “开饭” |
| UI 的实际 ASR 范围 | “开饭” | “开饭” |
| 跨文件测试实际使用的上下文范围 | “开放” | “开放” |
| 同一上下文换回单文件原始 PCM | “开放” | “开放” |
| UI 范围尾部增加 300 ms 诊断静音 | “开放” | “开饭” |

证据说明这条样本对输入范围和长度敏感；不能归因为丢失原音、物理文件分片或自动语言配置。尾部补静音也没有在两种语言配置下稳定修复，因此没有据此更改生产参数。

按去掉句号、保留数字的规则，此单句有 13 个参考字符、1 次替换，CER 为 7.69%。这是一个样本的质量基线，不是中文整体准确率。完整中文质量集与冻结阈值仍待验收。

UI 旅程核对真实 ASR 的时间片段、完整正文在重启前后不变、原音回放和删除；附件同时保留参考与实际全文。界面流程通过不表示 SV-ZH-001 已修复。跨文件集成测试仍要求全文精确匹配，并统一使用与手机相同的默认语言配置。原始失败、控制输入、源码和 JSON 保存在本机 `tmp_agent_output/20261014-momoagent-xcode/ui-archive-F885F930-EB9E-4DDA-BA87-FD93FD22FF1C/`。

## 尚需设备验证

iPhone 17 Pro 上的峰值内存、热状态、能耗、冷启动和最坏 20 秒 ASR 取消延迟尚未测量。Watch 真机后台持续录音、传输唤醒、真实录音 AAC priming / padding 元数据与模型远场质量也未验证。连续无静音时恢复重放的最坏开销仍可能随 epoch 增长；设备验收必须包含反复后台到期，不能只测短句平均速度。
