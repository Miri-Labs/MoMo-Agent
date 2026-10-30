# Watch 模拟器：原生采集与界面测试

2026-10-14 22:25：最终显示版本 `f2af6698…` 的 build06 和完整 UI 旅程通过，1/1、0 跳过、无 runtime warning，用例 109.423 秒，既定 120 秒期限未改；51 项输入哈希从构建至测试结束相同。证据 `tmp_agent_output/20261014-watch-blackhole-e2e-06/`，七张实图已读取，预览和测试原音均已清理。两项原生采样使用下述 `final-01` 中未变音频/运行时/测试源哈希的通过证据，本轮没有重跑 65 秒采样，不能称为新一轮 3/3。

2026-10-14 21:46 基线：三项正式用例在同一冻结产物上串行通过，3 通过、0 失败、0 跳过，runtimeWarnings 为空。证据 `tmp_agent_output/20261014-watch-blackhole-final-01/`，构建来源为 `…-e2e-04`，51 项源哈希保持一致。真实采集 68.5 秒，跨默认 60 秒 AAC 边界；新参考布局的完整 UI 旅程和重启保留原音也通过。输入为公开 fixture 经 BlackHole 的受控虚拟输入；旧 0 Hz、Swift 6 隔离及 UI 查询失败继续保留，完整边界见 [Watch 输入诊断](../../docs/implementation/watch-simulator-input-diagnosis.md)。

22:10 的点阵比例/字号/RMS 显示修补仅改变 `CaptureView.swift`。`…-e2e-05` 新构建及完整 UI 旅程 1/1 通过，用例 109.724 秒，未放宽 120 秒期限，51 项输入哈希稳定；两项原生测试沿用 `final-01` 中完全相同音频与测试源哈希的证据，本轮没有重跑 65 秒采样。七张实际截图和原音清理记录保留；视觉比例差异如实记录在诊断文档。

Apple 提供 watchOS Unit Testing Bundle 和 UI Testing Bundle。官方说明以 watch-only 工程为例；本项目用独立 `MoMoAgentWatchTests` scheme 测试现有单 target companion App，不经过 iPhone 测试宿主。本机 Xcode 27 的模板也允许直接关联 `application` 类型。[Apple 测试配置说明](https://developer.apple.com/documentation/watchos-apps/setting-up-tests-for-your-watchos-app)

## 验证范围

| 用例 | 实际调用与断言 |
| --- | --- |
| `WatchNativeCaptureTests/testNativeMicrophoneRotatesAACPausesMarksResumesStopsAndReopens` | 正式 WatchRuntime → WatchAudioSession → AVAudioEngine → CaptureEncoder → AAC → RecordingStore。等待实际采样达到 65 秒，跨过默认 60 秒分片边界；标记、暂停、继续采样至少 3 秒、停止；逐片读取并解码文件，核对帧区间、SHA256、字节数、epoch 结束位置、mark 和 SQLite 重开后的待确认原音。 |
| `WatchNativeCaptureTests/testPausedRuntimeRestoresSealedDurationWithoutRestartingMicrophone` | 实际采样至少 3 秒后标记并暂停，重新创建正式 runtime；恢复同一 session、暂停意图、已封口时长、mark 与待确认片段，不自动开启麦克风。此项是 runtime 重建；进程重启由下一项覆盖。 |
| `WatchCaptureJourneyTests/testRecordMarkPauseRelaunchResumeStopAndKeepPendingAudio` | XCUITest 点击开始，实际打开详情读增长时长并显式关闭，回主屏标记与“静音”（暂停）；terminate/relaunch 后再次打开详情核对暂停时长；继续录音，从“更多”进入结束确认，再重启检查两片原音仍待确认。所有读取/点击要求实际可见，保留录音中、暂停、更多、确认、停止及重启前后的七张截图。 |

时长来自实际 PCM 采样帧数。`ContinuousClock` 只控制测试超时，不向录音账本填充帧。测试保留默认 AAC/16 kHz/60 秒分片参数，不合成音频，不加速采样，不调用 ASR 或模型 API。宿主附件只含帧数、ID、哈希、计数和运行耗时，不附原音。

最短宿主用例会附加 `watch-input-availability-diagnostics-no-audio`：记录 guest 权限、session category/mode、可用输入、路由、采样率和通知时间。只有正式 `runtime.start()` 已失败并完成清理后，才重新激活同类 session，创建全新 engine，在立即、200 ms、1 s 读取输入/输出格式；不安装 tap、不启动 engine、不合成或保存原音，最后仍抛出原始失败。此探针只能用于缩小原因，不能替代正式录音或使失败变为通过。

模拟器使用 Mac 提供的音频输入。这能检验模拟器中的原生录音和文件链路，不能证明 Apple Watch SE2 麦克风、腕部声学质量、放下手腕后的后台采集、系统打断、18 小时稳定性或能耗通过。无音频设备、权限未授权或引擎未收到采样会明确失败，不退回伪造采样。

本机最终软件验收使用已获授权的 BlackHole 受控输入：公开 fixture 通过独立有限时长 ffplay 进程定向虚拟 CoreAudio 设备，专用 Watch 的 guest input 明确映射到 BlackHole；不改系统默认输入/输出。先用独立三秒探针确认正数实际帧/RMS，再运行正式用例。输入清单和复现步骤见 [探针说明](../../Tools/WatchCaptureProbe/README.md#受控虚拟输入)。这不是 Watch 物理麦克风或腕部效果验收。

## Debug 隔离

仅 `DEBUG && targetEnvironment(simulator)` 接受合法 UUID 环境变量 `MOMO_WATCH_TEST_RUN_ID`。AppDelegate 创建 runtime 前选择隔离目录：

```text
Library/Application Support/MoMoAgentSimulatorTests/<RUN_UUID>/
```

重启复用同一 UUID，保留目录。UI case 自行生成 UUID；两个宿主 case 也各自生成独立 UUID。scheme 环境中的 UUID 只隔离宿主 App 的启动状态，不与 case 目录混用。

隔离模式仍运行正式采集引擎，但产物 `sourceKind=fixture`。它不激活或发送 WatchConnectivity，也不接受来自配对手机的事件。传输页验证的是实际本地待确认队列，不伪造手机接收成功。Release 和真机编译不包含该入口。Release 产物检查应确认 `MOMO_WATCH_TEST_RUN_ID`、`MoMoAgentSimulatorTests`、`makeSimulatorTest` 和 `configureSimulatorTestCapture` 均未进入二进制。

文件传输仍需配对真机验收；Apple 明确不支持在 Simulator 使用 `transferFile`。本组测试不能算作 WCSession 文件传输或完整 Watch→iPhone E2E 通过。[Apple 文件传输说明](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))

## 运行

由负责环境的执行者准备专用 watchOS 27 Simulator；不要使用或重新配对当前 iPhone 验收设备。先安装 runtime、生成工程并枚举该 scheme 的可用 destination，再填入实际 Watch UUID。两个 target 串行运行，关闭并行和随机顺序。宿主复用 App 内的 Recording/Contracts/Link 符号，不重复链接这些静态包。

```sh
xcodebuild -project MoMoAgent.xcodeproj \
  -scheme MoMoAgentWatchTests \
  -showdestinations

xcodebuild -project MoMoAgent.xcodeproj \
  -scheme MoMoAgentWatchTests \
  -configuration Debug \
  -destination "platform=watchOS Simulator,id=$MOMO_WATCH_SIM" \
  -derivedDataPath DerivedDataWatch \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  build-for-testing
```

首次录音前，在已启动的专用 Watch Simulator 安装 App，再授予麦克风权限；同时确认 macOS 没有拒绝 Simulator 的麦克风访问。执行者可用 Simulator 的系统授权界面；若当前 runtime 支持 `simctl privacy`，可对指定 UUID 执行：

```sh
xcrun simctl install "$MOMO_WATCH_SIM" \
  DerivedDataWatch/Build/Products/Debug-watchsimulator/MoMoAgentWatch.app
xcrun simctl privacy "$MOMO_WATCH_SIM" grant microphone com.momoagent.ios.watchkitapp
```

授权仅影响这个专用测试设备。不要清空全机隐私数据库或修改主 iPhone Simulator。宿主测试本身不会绕过系统权限。

```sh
xcodebuild -project MoMoAgent.xcodeproj \
  -scheme MoMoAgentWatchTests \
  -configuration Debug \
  -destination "platform=watchOS Simulator,id=$MOMO_WATCH_SIM" \
  -derivedDataPath DerivedDataWatch \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  -resultBundlePath "$MOMO_WATCH_EVIDENCE/tests.xcresult" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  test-without-building > "$MOMO_WATCH_EVIDENCE/xcodebuild.log" 2>&1
```

`MOMO_WATCH_EVIDENCE` 必须是本轮独立证据目录；`.xcresult` 不能覆盖旧结果。可用 `-only-testing:MoMoAgentWatchIntegrationTests/WatchNativeCaptureTests` 或 `-only-testing:MoMoAgentWatchUITests/WatchCaptureJourneyTests` 分层定位。执行完成后导出 summary、测试明细及附件，实际打开截图核对状态与内容。

## 结束与证据边界

测试不在运行中的宿主内删除 SQLite 或录音目录，避免尚未释放连接时 unlink 文件。先停止本次 xcodebuild 和指定 Simulator 中的 `com.momoagent.ios.watchkitapp` 宿主，再由环境执行者清理本轮已确认归属的 UUID 目录，或删除整个专用 Simulator。不得按通配符删除其他 run 或普通 `MoMoAgent` 目录。

通过报告需分别记载：三个命名用例的结果、实际采样帧数、默认 60 秒片段和尾段、文件哈希与解码检查、mark、重启保留原音、UI 截图检查，以及 runtime/设备 UUID。构建成功、没有抛错或共享包测试通过均不能代替这些运行证据。
