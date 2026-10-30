# 构建与软件回放

以下命令从仓库根目录执行。正式平台构建需要完整 Xcode 27。当前机器已安装 Xcode 并完成许可和首次配置；平台构建与测试结果见[实施记录](status.md)。

1. 在终端完成 Xcode 首次配置。

```sh
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -checkFirstLaunchStatus
xcodebuild -showsdks
```

2. 准备模型和公开测试音频。脚本使用固定版本并核对哈希，Models 目录不进入 Git。

```sh
uv run Native/SpeechVendor/prepare-models.py Models/Speech --scratch-directory tmp_agent_output/model-download
uv run Tests/Support/prepare-fixtures.py Models/TestFixtures --scratch-directory tmp_agent_output/fixture-download
```

3. 构建并运行共享模块测试。

```sh
momo_test_run="$PWD/tmp_agent_output/package-tests-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$momo_test_run/model"
for model_file in manifest.json model.int8.onnx tokens.txt silero_vad.onnx; do
  ln -s "$PWD/Models/Speech/$model_file" "$momo_test_run/model/$model_file"
done
ln -s "$PWD/Models/TestFixtures" "$momo_test_run/model/test_wavs"
env -u MOMO_E2E_API_KEY \
  MOMO_SPEECH_MODEL_DIRECTORY="$momo_test_run/model" \
  MOMO_TEST_OUTPUT_DIRECTORY="$momo_test_run/output" \
  swift test --package-path Packages/MoMoAgentKit \
  --force-resolved-versions --no-parallel -j 2
```

临时目录中的符号链接让包测试同时读取模型和公开音频，不复制模型。没有 `MOMO_SPEECH_MODEL_DIRECTORY` 时，原生 ASR 用例会跳过；不要将这种运行算作本地 ASR 验收。上述命令显式清除远端测试密钥，真实百炼验收另按后文执行。

4. 打开根目录的 MoMoAgent.xcodeproj。选择 MoMoAgent scheme 和实际可用的 iPhone 模拟器。当前先验证模拟器，使用 ad-hoc 签名，不需要真实开发证书：

```sh
xcodebuild build-for-testing -project MoMoAgent.xcodeproj -scheme MoMoAgent \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

不要用 `CODE_SIGNING_ALLOWED=NO` 跑 Keychain 验收；它已导致模拟器宿主出现 entitlement -34018。使用上述签名方式后，两项凭据回归通过；最新 `ios-build-29` 构建通过，`ios-tests-16` 共 60 项，55 通过、5 项收费 Live Agent 测试跳过、0 失败。今后安装到真机时，再在已忽略的 Config/Local.xcconfig 中配置 DEVELOPMENT_TEAM 并完成设备配对。

project.yml 是工程配置来源；新增文件后使用 XcodeGen 2.46.0 重新生成。工程只把 Contracts、Recording、Link 链接到 Watch，ASR 和 Pi 留在 iPhone。

## 版本与交付

手机与手表共用 `Config/App.xcconfig` 中的版本。`MARKETING_VERSION` 是用户看到的三段版本号，例如 `1.0.1`；`CURRENT_PROJECT_VERSION` 是内部递增构建号。两端 Info.plist 引用这两个值，界面只显示三段版本号。Apple 对用户可见版本的格式要求见 [CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)。

修复递增末位，功能更新递增中间位并将末位归零，重大不兼容改版递增首位并将后两位归零。同一版本的构建重试沿用版本号；交付新的构建时递增内部构建号，保存到配置并提交。构建命令不再用 `MARKETING_VERSION=...` 或 `CURRENT_PROJECT_VERSION=...` 临时覆盖。

Release 构建后核对实际手机包与内嵌手表包。检查器会拒绝版本格式不符、两端不一致或产物与当前配置不符的情况：

```sh
uv run Tests/Support/verify-release-bundle.py \
  --app /绝对路径/MoMoAgent.app \
  --output tmp_agent_output/本次任务/release-bundle.json
codesign --verify --deep --strict /绝对路径/MoMoAgent.app
```

新交付产物使用 `MoMoAgent-1.0.1.app` 这样的名称。交付记录同时保留版本号、Git 提交及检查结果。历史记录中的旧版本格式按当时证据保留。

## 测试目标与既有结果

MoMoAgent scheme 现有两个测试 target：MoMoAgentIntegrationTests 执行真实本地转写、静音、删除竞态与原生回放；MoMoAgentUITests 执行设置、资料恢复与完整界面旅程。设备运行命令见 [iPhone 集成测试](../../Tests/iPhoneIntegrationTests/README.md)。UI 旅程使用 Debug 专用固定音频入口，每例 UUID 隔离，经过真实收件和 ASR；重启保留同一 UUID 的资料，不连接实际 Watch。

2026-10-14 的 Release 第 8 轮 ad-hoc 签名构建与 10 项产物检查通过。产物不含 TestFixtures、UI 测试环境变量、领取/停止/入场同步门、Live Agent 凭据入口或凭据探针，四项模型资源哈希与固定模型一致；后台任务与隐私 API 用途声明已打包。证据为 `ios-release-build-08.log` 与 `ios-release-bundle-08.json`。安装后已启动并核对截图，无 Watch 配对时正常进入空聊天主页，没有 Debug 导入或启动错误，证据为 `ios-release-launch-08-retry.log/.png`。首次启动因模拟器未开机失败的日志另行保留。真机、归档和发布仍未验收。

第 16 轮的 9 项原生回放生命周期用例通过，xcresult 的运行时警告列表为空；原始日志仍有测试提前清理目录引起的 SQLite 提示，不能概括为日志完全无警告。详情见[实施记录](status.md)。

## 已运行的共享软件检查

存储检查使用真实 PCM、文件和 SQLite；测试正文明确由 fixture 提供，不包含 ASR 或模型 API。

```sh
swift run --package-path Tools/CaptureReplay CaptureReplay verify-storage --output /绝对路径/全新结果目录
```

CaptureReplay 的 65.25 秒实时 AAC、20 倍 AAC/PCM 和 SIGTERM 短尾均已验证，原有存储检查 11 项通过。完整运行各确认 1,044,000 帧，源流哈希一致；PCM 解码哈希一致。它每块最多生成 512 帧，经生产分片器和两端 SQLite 保存；不运行 ASR 或模拟 WatchConnectivity。Release 构建、共享 scratch 的串行要求及精确参数见 [CaptureReplay README](../../Tools/CaptureReplay/README.md)。18 小时实时模式尚未运行。

本地转写检查使用实际应用协调器、Silero、SenseVoice 和 SQLite。第二个参数是公开中文 WAV 样本，第三个参数必须是新目录。结果包含 evidence.json 和各场景档案，不会清空已有目录。

```sh
swift run --package-path Tools/PhonePipelineReplay PhonePipelineReplay /绝对路径/模型目录 /绝对路径/zh.wav /绝对路径/全新结果目录
```

当前验证样本来自固定的 sherpa SenseVoice 模型发布包。模型来源、版本、权重许可和下载方法见 [SpeechVendor](../../Native/SpeechVendor/README.md) 与[本地转写实施记录](local-speech.md)。单句识别通过不代表已经完成中文质量集验收。

流水线还有不依赖模拟器的代码级回归，直接编译生产协调器，使用真实 SQLite、VAD 与 SenseVoice。它覆盖分析与识别重叠、关闭预取后串行运行、暂停与后台到期后的断点恢复，并核对删除后的原音租约释放。复用上文第 3 步准备的模型和公开音频链接：

```sh
env -u MOMO_E2E_API_KEY \
  MOMO_SPEECH_MODEL_DIRECTORY="$momo_test_run/model" \
  MOMO_TEST_OUTPUT_DIRECTORY="$momo_test_run/output" \
  swift test --package-path Tools/PhonePipelineReplay \
  --force-resolved-versions --no-parallel -j 2
```

## 真实 Agent、百炼与设备验收

iPhone 模拟器上的 `LiveAgentContextTests` 已通过真实 OpenRouter 的 5 项上下文场景（live04 direct，`anthropic/claude-sonnet-4.6`）。live02 为 5/5，live03 因本机代理连接/TLS 错误仅 1/5；live04 direct 已复跑通过，无跳过、工具错误或运行时警告。独立 Keychain 写入、重开和生产鉴权头检查在 ad-hoc 签名后 2/2 通过；该项使用本地 HTTP 探针。收费测试的显式凭据入口与证据要求见 [iPhone 集成测试](../../Tests/iPhoneIntegrationTests/README.md#真实-agent-测试)。

5/5 为自动断言结果。人工复核仍发现最终回答复述已取消地点/口令，以及完整读稿后误判截断并重复搜索两项问题；计划本体没有旧值污染。详见[实施记录](status.md)。

App 设置中进入“模型 API 与密钥”，选择百炼北京地域，填写同地域按量付费密钥。默认 qwen-plus 和北京 Chat Completions 地址；可换为百炼控制台提供的业务空间地址。密钥只保存在 Keychain，不写入工程或测试结果。

百炼 API 测试入口、环境变量与验证边界见[百炼验收说明](bailian-validation.md)。缺少凭证时相关测试跳过，不算通过。OpenRouter、Pi Faux 和发包探针分别记录，不能替代真实百炼 API 验收。

新增的 [LifeContextReplay](../../Tools/LifeContextReplay/README.md) 将本次真实 ASR 结果接入 Pi 与百炼，再核对模型保存计划的来源和可解码原音。它仅接受显式测试密钥，缺密钥时记录 not-run 并退出 64，不读取或改写 App Keychain。该命令行入口尚未执行真实 API 贯通；iOS OpenRouter 宿主结果独立记录。

没有 Watch 时，可以在 Mac 回放共享录音处理链路，并在 iPhone 模拟器或手机测试资料与助理界面。WatchConnectivity、后台录音和 18 小时覆盖必须在配对设备上单独验证。完整门槛见 [E2E 方案](../plan/e2e-test-plan.md)。
