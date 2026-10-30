# iPhone 转写与 Agent 集成测试

`MoMoAgentIntegrationTests` 是由 iPhone App 承载的 XCTest target，已加入 `MoMoAgent` scheme。它直接编译生产 `TranscriptionCoordinator`，并复用 Mac 回放使用的 `TranscriptionIntegrationScenario`。scheme 给宿主设置固定的 `MOMO_UI_TEST_RUN_ID`，让宿主使用 Debug 隔离档案并关闭 WatchConnectivity；不设置导入标记。测试各自创建 UUID 临时档案。普通本地用例不需要 Watch 或模型服务；`LiveAgentContextTests` 只有收到显式测试凭据才调用收费 API。

转写与回放入口：

- `testCrossFileTranscriptionAndSavedContextLifecycle`：一句中文跨两个 60 秒文件，真实 Silero / SenseVoice 生成正文；检查暂停恢复、来源、搜索、跨文件原音、计划去重和删除后的迟到文件。
- `testSilentRecordingWaitsForForegroundAndCompletesWithoutASR`：启动挂起，显式恢复后处理静音，不创建 ASR 正文。
- `testDeleteDuringNativeRecognitionRejectsLateResultAndReleasesAudio`：在真实 native decode 入口设置测试同步点，删除立即建立屏障；原音保留到租约释放，迟到结果不能提交。
- `testNativePlaybackKeepsAudioLeaseUntilExplicitStop`：调用 App 的真实 AVAudioPlayer 回放；一秒后仍保持播放，删除期间通过 lease 保留原音，停止后释放并清理。此例使用明确标注的测试正文，只验证回放和资源生命周期，不计作 ASR 结果。
- `testFileRevisionDuringRecognitionContinuesWithoutNewAudio`：识别期间从文件修订正文，旧 attempt 不得覆盖修订；已有音频恢复处理，不依赖新文件唤醒。
- `testRepeatedFileRevisionsStopRetryingAndCanResume`：连续修订触发有界停止，待处理音频保留；用户重试后继续完成。
- `testDeleteDuringAnalysisClaimContinuesOtherRecording` 与 `testDeleteDuringRecognitionClaimContinuesOtherRecording`：任务已领取原音租约、尚未进入分析或识别时删除，迟到任务释放租约，另一条录音继续完成。
- `testDeleteDuringClaimPreservesUserPauseUntilExplicitResume`：上述领取窗口内删除并暂停，暂停状态保持，用户显式恢复后才识别剩余录音。

`AudioPlaybackIntegrationTests` 共 9 项，除上述真实 AVAudioPlayer 场景外，还控制会话激活、播放器准备、停止与失败的顺序，检查取消和新旧播放请求不会提前释放租约或相互停止。音频会话与播放器由串行执行者持有，原生准备、播放与停止不在 MainActor 执行；受控失败用例不冒充真实设备故障。

资料与助理入口：

- `PlanRecoveryIntegrationTests`：已删除计划的路径被换成符号链接时，报告清理失败，同时允许手机继续启动；链接目标不变。
- `PhoneReceiveStatusTests`：3 项真实档案与生产接收协调器场景；系统缓存状态不会触发对账或确认，错误资料库不能替换报告，重启后继续处理持久请求，失败的对账响应重新入队。运输回调由测试控制，不表示 WatchConnectivity 真机投递已验收。

- `LibraryPaginationIntegrationTests`：真实档案中写入 51 条录音，检查加载更多、刷新后保留可见范围及删除后的数量。
- `AssistantDraftIntegrationTests`：4 项用例检查中文 UTF-8 超限、最大长度输入缺配置、失败期间的新草稿，以及旧重试请求与新请求前置失败的区分。最后一项使用真实 Pi 和 Archive，模型响应来自 Pi 官方受控 Provider，不访问模型服务。
- `ProviderCredentialIntegrationTests`：2 项本地边界回归；真实模拟器 Keychain 保存与重开，再核对生产 Pi 生成的两次 Authorization 头；错误诊断不包含服务端原始正文或鉴权值。HTTP 响应来自本地 URLProtocol，不计作真实模型验收。

系统任务与导出入口：

- `TranscriptionBatchIntegrationTests`：真实 SQLite、VAD 与 ASR；覆盖批次到期、旧原生调用交接、并发停止共享持久屏障、领取期间到期，以及前后台和暂停恢复的状态竞争。测试用同步门控制时序，不用睡眠推测竞态。
- `BackgroundGrantLifecycleTests`：4 项受控系统事件场景；准备期间到期不再入场，入场期间到期等待持久停止，完成可先于 handle 返回，屏障失败仍只结束一次并报告失败。
- `AutomaticBackgroundSubmissionTests`：2 项固定 identifier 提交与取消场景；迟到提交先取消，用户恢复后的新提交再执行；资格查询期间取消不提交。
- `ArchiveExportLifecycleTests`：3 项真实档案导出场景；SwiftUI 消失不提前删除分享副本，系统完成后幂等清理，准备取消不展示，完成早于页面消失也不能串扰下一次导出。

这些平台生命周期用例控制系统回调，不证明 iOS 已实际授予后台预算。UI target 另外使用真实系统分享页验证取消后可再次导出，并检查设置中的本机容量；实际分享目标写入文件和真机锁屏仍须单独验收。

跨文件例要求归一化全文精确匹配、一个正文段落、一个窗口和一次原生识别；删除例要求同步门未超时，并核对识别开始、删除提交、取消、释放与原生返回的顺序。

领取竞态使用 Debug 专用 async continuation 同步门，放在 Archive 返回已持有 lease 的 ticket 之后、协调器接管之前，不使用固定等待时间制造竞态。另有持久停止完成、批次入场返回处的同步门。Release 不编译这些入口。

最新 `ios-tests-16` 使用 `ios-build-29`：集成 target 48 项通过、5 项收费 Live Agent 测试跳过，UI target 7 项通过，共 60 项、0 失败。9 项回放用例全部通过，xcresult 的 `runtimeWarnings` 为空；原始日志仍有导出、手机状态和计划恢复测试提前清理目录引起的 SQLite vnode 提示，清理时序另行定向复测。此前第 15 轮关闭签名造成的 Keychain entitlement -34018，已在 ad-hoc 签名的两项凭据回归和本次完整套件中通过验证。真实模型结果单独记录，见[实施记录](../../docs/implementation/status.md)。

`ModelRecoveryIntegrationTests` 三项真实故障/恢复用例已在 Debug09 `ios-model-recovery-27-02` 全部通过：缺模型时 PhoneRuntime 仍能启动和保留收件；模型准备阶段文件缺失或哈希损坏时不进入原生解码；换回完整固定模型后对原 session/原音继续真实转写，最后删除能释放文件。测试只改独立临时模型目录，不改签名 App 或已安装的模型。它不包含模型下载管理或错误页面的 UI 点击验收。

## 准备资源

从仓库根目录执行：

```sh
uv run Native/SpeechVendor/prepare-models.py Models/Speech \
  --scratch-directory tmp_agent_output/ios-model-download
uv run Tests/Support/prepare-fixtures.py Models/TestFixtures \
  --scratch-directory tmp_agent_output/ios-fixture-download
```

若模型包内已有 `test_wavs/zh.wav`，第二条命令添加 `--source-wav Models/Speech/test_wavs/zh.wav` 可复用文件。脚本会校验 SHA256；不匹配就失败。未提供本地样本且目标缺失时，脚本从固定官方发行包提取样本。来源、参考文字和哈希保存在 [SpeechFixtureMetadata.json](../Support/SpeechFixtureMetadata.json)。下载资源写入已忽略的 `Models/`，不提交二进制。

测试从宿主 App 的 `Speech/` 读取模型，从测试 bundle 的 `TestFixtures/zh.wav` 读取音频。没有 Mac 路径或环境变量模型路径。缺模型、缺音频或哈希错误都会使测试失败，不跳过。

App 另有 Debug 专用脚本复制 `TestFixtures`，供 UI 旅程使用。Release 不复制，并清除该 App bundle 中残留的同名测试资源目录。共享音频生成 helper 只编入测试和 Mac 工具，未加入手机产品依赖。

## 运行

资源准备后，用项目约定的 XcodeGen 版本生成工程，再枚举当前机器的运行目标：

```sh
xcodegen generate --spec project.yml
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgent -showdestinations
```

当前先使用 iOS Simulator。将下列占位符换成实际模拟器 ID 和新的结果目录；ad-hoc 签名不需要真实开发证书：

```sh
xcodebuild test -project MoMoAgent.xcodeproj -scheme MoMoAgent \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -only-testing:MoMoAgentIntegrationTests \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  -resultBundlePath tmp_agent_output/ios-integration-RUN_ID.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

使用串行测试，避免同一设备同时加载多个原生模型影响结果。测试会执行真实推理和本地存储；模拟器结果不能替代手机热状态、锁屏、后台预算或 WatchConnectivity 验证。此 target 接线本身不代表测试已经通过。

不要用 `CODE_SIGNING_ALLOWED=NO` 验收模拟器 Keychain，它会让宿主缺少所需 entitlement。今后运行真机时需要另行配置开发团队与设备签名，不能沿用此模拟器签名命令。

## 真实 Agent 测试

`LiveAgentContextTests` 的 5 个收费场景使用生产 AssistantModel、Pi system prompt、上下文和六个本地工具：近期讨论直接保存来源计划；旧资料搜索并读取完整稿件；同会话接收新录音及正文修订后拒绝旧会话；转录内指令不能授权写计划或播放；真实跨文件 Silero/SenseVoice 转录进入来源计划。前四项正文为显式合成 fixture，第五项为真实 ASR 结果。

2026-10-14 的 live04 direct 使用 OpenRouter `anthropic/claude-sonnet-4.6`，5/5 通过、无跳过、工具错误或运行时警告；`accepted=true`，临时凭据已删除。此前 live02 为 5/5，live03 因系统代理连接与 TLS 错误为 1/5，失败结果保留。阿里云百炼尚未执行真实请求。

上述通过范围是现有自动断言。人工语义复核仍发现：最终回答在括号中重复已取消的地点和口令，虽未污染保存计划，却违反用户要求；旧稿两页已覆盖完整正文，模型仍误称截断并追加两次无新信息的搜索。两项仍未修复，证据见本机 `live-agent-04/scenarios/semantic-review.md`；不能将工具零错误等同于分页语义或最终回答完全正确。

先完成 Debug `build-for-testing`，再使用独立测试凭据文件。文件包含一个 `OPENROUTER_API_KEY`，密钥不放命令行；脚本只读取明确指定的文件。输出目录必须为新目录。

```sh
uv run Tests/Support/run-live-agent-e2e.py \
  --credential-env-file /绝对路径/独立测试凭据文件 \
  --model anthropic/claude-sonnet-4.6 \
  --simulator SIMULATOR_ID \
  --derived-data DerivedData \
  --network-route direct \
  --output /绝对路径/全新结果目录
```

`direct` 只修改本次测试的 URLSession 代理配置；`system` 使用系统配置，不修改 Mac 系统网络设置。真实测试使用内存凭据存储，不能替代上面的 Keychain 回归。脚本把密钥写入权限 0600 的临时文件，结束后同时检查原容器与重装后的当前容器并删除凭据；停止宿主后仅导出预期场景的脱敏 JSON，再清理原始运行数据库。验收要求 5 个指定报告与本次 runID/model/网络路径匹配，xcresult 中 5 项 Passed、0 Skipped、0 Failed；缺凭据时普通 XCTest 会跳过，不能记作 API 通过。

测试 target 通过 `TEST_HOST` / `BUNDLE_LOADER` 复用宿主已有模块，只单独链接手机 App 没有包含的 MoMoRecording。不要再次给测试 target 添加 Archive / Speech 产品链接，否则 Xcode 自动产品转换可能让同一 Archive 类同时出现在宿主和动态框架中。

转写与回放用例保留运行后的文件和数据库，XCTest 附件记录目录位置；草稿用例在结束后清理自己的临时目录。需要查看保留档案时，先导出对应 App 容器。设备临时目录可能被系统清理，因此不能只依赖路径附件长期保存证据。

当前 `run-live-agent-e2e.py` 的 context 与 quality 都把 `accepted` 保持为 false、`semanticReviewStatus` 标为 pending。退出码只说明自动断言和清理是否通过；回答和落盘计划必须另做独立事实复核，旧失败报告不回写。
