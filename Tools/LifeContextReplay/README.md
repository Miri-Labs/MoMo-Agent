# 录音上下文到 Agent 回答的贯通测试

2026-10-15：当前链路为真实 ASR → 助理回答 → 引用原音校验，不再创建计划。下文已有计划结果属于旧版证据。

此工具执行真实链路：公开中文 WAV → 分片收件与 SQLite → Silero VAD + SenseVoice → PiDurableKit → 百炼模型 API → 带来源的回答 → 跨文件原音读取。

转录正文必须来自本次 ASR。工具通过相对符号链接复用 `PhoneTranscriptionFixture`、`TranscriptionIntegrationScenario` 和手机端 `TranscriptionCoordinator`，不复制协调器，也不预填转录或直接调用 `savePlan`。

## 运行

需要 Apple Silicon Mac、完整 Xcode 27、已校验的 [本地模型包](../../Native/SpeechVendor/README.md)，以及通过 `Tests/Support/prepare-fixtures.py` 准备的官方 `zh.wav`。夹具 SHA-256 固定在共享 helper 中；57 秒前置静音使同一句语音跨过两个 60 秒文件。

这是 **Debug 诊断入口**。它使用 `@testable import MoMoAgent` 访问现有测试注入点，随后调用生产 `PiAgentHost.submit` 与上下文策略。`Models(credentials: .inMemory)` 只在进程内持有测试密钥，不读取或修改应用 Keychain。Release 构建会直接拒绝编译。

通过安全输入或 CI secret 显式提供 `MOMO_E2E_API_KEY` 后运行。工具不会读取任何 `.env`。默认使用百炼北京按量付费 `qwen-plus`；可用 `MOMO_E2E_BASE_URL` 指定北京业务空间地址，用 `MOMO_E2E_MODEL` 指定兼容模型。此调用会产生模型 API 费用。

```sh
swift run --package-path Tools/LifeContextReplay --force-resolved-versions \
  -Xswiftc -enable-testing -c debug LifeContextReplay \
  /absolute/path/to/Models/Speech \
  /absolute/path/to/Models/TestFixtures/zh.wav \
  /absolute/path/to/tmp_agent_output/life-context-01
```

输出目录必须尚不存在。没有显式密钥时，工具写入 `evidence.json`，标记 `status: "not-run"`、`failureCode: "missing_explicit_test_api_key"`，然后以 **64** 退出。此时不开始 ASR，也不发送模型请求。环境中有空密钥时同样处理；不会切换为模型替身。

## 通过条件

- 本次真实 VAD/ASR 完成至少一个窗口，识别出官方示例的预期片段，并保留跨两个物理文件的来源区间。
- Pi 使用当前录音工具集合：`get_context_status`、`list_recordings`、`search_transcripts`、`read_transcript`，以及已有记忆工具。此入口不接入系统行动与健康服务；模型自行选择按需读取的工具。
- 模型回答非空，回答中的 `momoagent://source/...` 链接均匹配本次 ASR 的 session、span、版本和 generation。
- 每项来源通过 Archive 校验，回放区间与转录来源区间一致，原文件指定范围可实际解码。文件句柄在同步读取结束时释放，所有音频租约在后续操作前释放。

上述检查完成后才写 `status: "passed"` 并以 **0** 退出。失败退出码为 **1**，证据记录失败阶段和错误类型，不记录密钥或供应商错误正文。`registeredTools` 表示已注册的工具，不表示它们全部被调用。

`capture/` 保存公开测试音频；`phone/` 保存真实转录及索引；`agent/` 保存 Pi 会话。`evidence.json` 记录转录和回答哈希、来源链接解析结果，以及每段原音的实际解码帧数。语义验收需另读模型回答，检查时段、待确认项和事实是否忠于转录；程序的来源断言不替代这项判断。

## 历史证据范围

2026-10-14，该入口已使用完整 Xcode 27.0（27A266a）、Swift 6.4 和官方 Pi 固定 revision `885ada3f14c17f48da85c3ac8b359e7f81a8b84f` 正式构建成功，包含上游 `FoundationModelsProvider.swift`。构建采用 Debug 与 `-Xswiftc -enable-testing`，复用主包的构建目录；依赖版本保存于本工具的 `Package.resolved`。

随后显式移除 `MOMO_E2E_API_KEY` 执行正式产物，退出码为 64。输出目录只有 `evidence.json`，其中 `status` 为 `not-run`、`failureCode` 为 `missing_explicit_test_api_key`、`remoteRequestStarted` 为 `false`；程序在读取音频或启动 ASR 前退出。本轮未调用付费模型 API。真实 ASR → Pi → 百炼 API → 带来源计划的贯通运行仍待显式测试密钥；构建成功和缺密钥退出不计为贯通测试通过。

此工具验证 Mac 上共享的软件链路。Watch 麦克风、WatchConnectivity、iPhone 后台预算和设备能耗仍需设备测试。
