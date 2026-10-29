# 手机软件链路回放

这个命令在 Mac 上运行真实录音文件、SQLite、Silero VAD、SenseVoice 和手机端转写协调器。测试源文件通过仓库内的相对符号链接引用，直接编译 `Apps/iPhoneApp/Application/Transcribing/TranscriptionCoordinator.swift`、`Tests/iPhoneIntegrationTests/TranscriptionIntegrationScenario.swift` 和 `Tests/Support/PhoneTranscriptionFixture.swift`。后两者也由 [iOS 集成测试](../../Tests/iPhoneIntegrationTests/README.md) 使用。

需要 Apple Silicon Mac、Swift 6.2，以及 [已校验的本地模型包](../../Native/SpeechVendor/README.md)。首次构建由 SwiftPM 获取固定版本的官方 XCFramework。模型准备完成后，推理全程离线。

从仓库根目录运行。第二个参数使用官方 SenseVoice 转换包中的 `test_wavs/zh.wav`，或通过 `Tests/Support/prepare-fixtures.py` 准备的 `Models/TestFixtures/zh.wav`；两者必须匹配固定 SHA256。第三个参数必须是尚不存在的输出目录，工具不会覆盖已有数据。

```sh
swift run --package-path Tools/PhonePipelineReplay PhonePipelineReplay \
  /absolute/path/to/Models/Speech \
  /absolute/path/to/sherpa-model/test_wavs/zh.wav \
  /absolute/path/to/tmp_agent_output/phone-pipeline-01
```

工具先插入 57 秒静音，再通过生产 `PCM16SegmentWriter` 写入语音，迫使一句话跨过两个 60 秒物理文件。中文预期为“开放时间早上9点至下午5点”，来源是 [sherpa 官方示例](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html#with-inverse-text-normalization)。

基础命令保留 VAD 筛选模式，用于核对原有接口。检查包括：

- 收件校验、SQLite 落库、暂停状态重建，以及显式恢复转写。
- 跨文件 VAD/ASR、原音来源、JSON/Markdown 投影、中文搜索和两段回放。
- 相同操作保存计划的去重、删除后的上下文失效，以及迟到文件拒绝。
- 启动时暂停执行、全静音录音完成且不创建 ASR 窗口。
- 在真实 native decode 入口暂停测试线程，删除 session 并取消任务。屏障立即生效，原音保留到读取租约释放，返回结果不能重新生成正文。

成功后输出 `evidence.json`。`phone/`、`silence-phone/` 与 `delete-during-native/` 各保存独立数据库。删除场景会删除对应应用目录中的录音和正文；`capture/` 留存公开测试音频，便于复跑检查。

这是 Mac 上的共享软件链路集成验证。iPhone 后台预算、热状态、能耗、WatchConnectivity 和真实 Watch 持续录音需要设备验证。

## 一小时稀疏录音吞吐

加上 `--sparse-hour`，用同一条已校验的公开中文音频，每分钟播放一次，其余补静音，生成一小时、60 个物理片段。工具不发送录音结束事件，使用真实接收、SQLite、生产协调器、Silero VAD、SenseVoice 和文档投影处理已接收范围。此模式与手机一致，开启 `continuousArchive`：由 Silero v6 选择语音范围，保留语句和跨窗口上下文。跳过的非语音范围也提交处理进度。

```sh
swift run --package-path Tools/PhonePipelineReplay PhonePipelineReplay \
  /absolute/path/to/Models/Speech \
  /absolute/path/to/Models/TestFixtures/zh.wav \
  /absolute/path/to/tmp_agent_output/sparse-hour-01 --sparse-hour
```

`throughput.json` 记录已接收与已处理时长、导入耗时、处理耗时、RTF、窗口核心覆盖时长、VAD 输入时长和原生识别耗时。`recognitionInputSeconds` 是实际送入识别器的音频时长，含重叠上下文；`skippedSeconds` 是未进入识别的核心范围。`asrCoreSeconds` 不包含上下文，实际推理耗时看 `nativeASRSeconds`。`speech-diagnostics.json` 保存读取、哈希、模型加载、排队和分析背压等分项。RTF 是处理耗时除以音频时长；一小时在五分钟内处理完对应 RTF 不超过 0.08333。

处理计时包含本次运行的模型校验与加载、VAD、ASR、事务提交和文档投影；不含夹具生成、导入、构建与模型下载。该命令不运行手机界面层。重复式干净语音加静音用于回归吞吐和时间覆盖，不能代表真实环境噪声、不同说话人或识别质量，也不能代表手机速度。测手机时还要分别记录系统授予执行前的等待时间。

## 连续语音与恢复

`CompleteRecordingTests` 使用生产协调器处理连续的公开中文语音，检查跨文件、跨两分钟分析批次、识别中取消和重建后的正文。测试不发送录音结束事件，逐字核对 24 次已知句子，且再次运行不能重复写入。另一个用例先处理前一分片，再收到后一分片，核对跨分片语句是否完整。模型测试使用独立目录，包含已校验的四个模型文件及 `test_wavs/zh.wav`；不要把测试 WAV 加入生产 App 资源。

```sh
MOMO_SPEECH_MODEL_DIRECTORY=/absolute/path/to/test-models \
  swift test --package-path Tools/PhonePipelineReplay --filter CompleteRecordingTests
```

自然录音副本回归可额外设置 `MOMO_RECALL_SAMPLE_MANIFEST`，内容为 JSON 数组，每项包含 `id`、`path`。有人工核对依据时，可设置 `minimumCharacters` 和 `maximumCharacters` 作为附加断言；未标注样本只记录诊断结果。测试使用手机默认 VAD 阈值 0.25。测试只在临时资料库中处理副本，输出字数、音频时长、处理耗时、选中与跳过范围、实际 ASR 输入时长和原生识别耗时，不写回手机或原资料库。字符数只能确认是否得到正文，不能代替人工标注的准确率。个人录音、清单与结果均保存在已忽略的任务目录。
