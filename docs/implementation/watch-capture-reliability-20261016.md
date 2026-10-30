# Watch 采集可靠性与时间线补齐 · 2026-10-16

本轮修正启动、暂停与系统中断的状态表达，增强手表麦克风准入、恢复和停录诊断，并补齐 iPhone 日期范围、局部失败与已配置摘要。工作分支为 `codex/watch-capture-reliability`。当前 Watch 模拟器完整测试通过 21/21；iPhone 的 `ios-build15` 最终默认回归为 33 通过、0 失败、1 明确跳过，受控本地 HTTPS 摘要闭环另轮通过 2/2。旧输入实现的宿主 26/26 单独保留，不覆盖之后的输入框候选与首页 Avatar 改动。当前已恢复与 main 一致的原始 SwiftUI 输入实现；DeviceHub 在 `ios-build14` 上实际操作并持久保存了精确的两行 `A\nB`，六行/七行边界与中文输入法仍未验收。最终 `Release01` 已构建成功、静态产物检查 19/19、严格签名验证通过，安装与普通启动检查也已通过。模拟器已有真实采样证据，但尚不能据此确定用户真机自行停录的具体原因，或宣布真机持续录音已验收。

## 采集行为与定位入口

- [CaptureView](../../Apps/WatchApp/Features/Capture/CaptureView.swift) 按真实意图和活动状态显示操作：启动中为不可重复点击的“正在启动”，录音中为“静音”，用户暂停后为“解除静音”，系统中断后为“继续录音”，失败为“重试录音”。启动和中断不再被统称为静音；现有点阵、布局及单一运行时入口保留。
- [WatchAudioSession](../../Apps/WatchApp/Platform/WatchAudioSession.swift) 使用 `.record`、空 `categoryOptions`，不启用 Bluetooth HFP 输入，并在激活后核对实际输入是否为内置麦克风；路由失效时关闭输入准入。watchOS SDK 不提供可用的 `setPreferredInput`，本轮没有调用它，也不把这一策略描述为已经验证物理耳机切换。
- [WatchRuntime](../../Apps/WatchApp/Application/WatchRuntime.swift) 在清理前保存所属 epoch 和诊断上下文，按当前录音意图处理恢复；迟到的中断结束、路由或重置事件不能撤销用户暂停。诊断持久化失败仍继续停止、封口和保留已录原音，错误会被报告。
- 容量预检或开片检查拒绝后，成功收尾仅追加 `.finalized` 历史，不覆盖可见的 `.lowSpace` 原因，原容量错误仍报告给用户；真实存储或音频会话清理错误继续按 `.cleanupFailed` 报告。重开运行时仍读取最近的非收尾诊断。
- “更多 → 采集诊断”读取本地账本最近保留的 64 条事件中属于当前录音的记录，展示时间、原因、阶段、输入路由及 tap / 编码进度。tap 到达代表收到输入回调，编码进度代表处理链已经推进，两者不能互相替代；因此可以区分没有输入、输入被拒绝、编码停滞与收尾失败。计数与有界持久化见 [CaptureTapHealth](../../Packages/MoMoAgentKit/Sources/MoMoRecording/Capture/CaptureTapHealth.swift) 和 [CaptureDiagnostics](../../Packages/MoMoAgentKit/Sources/MoMoRecording/Ledger/CaptureDiagnostics.swift)。

## 已执行证据与当前源码范围

| 轮次 | 实际结果 | 可证明的范围 |
| --- | --- | --- |
| `watch-build02` / `watch-tests03` | 构建成功；历史 **19/19**，16 项原生测试、3 项 UI，0 跳过，结果中无 runtime warnings | watchOS 27 模拟器上的真实输入、运行时故障恢复、账本与 UI 旅程；不是物理 Watch 验收 |
| `watch-build03` / `watch-tests04` | 构建成功；当前默认字号 **21/21**，19 项原生测试、2 项 UI，0 跳过，结果中无 runtime warnings | 当前路由准入、真实采样和两种容量拒绝、系统事件恢复、账本与同步控制、默认字号完整 UI 旅程；测试后 Watch 与供音已停止，不代表物理配对或系统事件验收 |
| `package03` | Recording **7/7**；Archive **32/32** | 当轮采集计数与诊断持久化、时间线范围和播放相关定向包测试；不是最终源码的全部共享包回归 |
| `package04`–`package06` | 后续复跑未进入测试；依赖获取失败，`package06` 明确为二进制下载 TLS 错误 | 不能把旧 `package03` 结果视为后续改动已经全包通过 |
| HTTP fixture 自检 | **22/22** | 本地受控 HTTPS 服务的闭集响应、请求检查和生命周期；与下面手机摘要结果分别记录 |
| `ios-build03` / `ios-tests02` | 构建成功；宿主 **13 通过、1 失败** | 模型恢复 7、日期 4、阅读模型 2 通过；真实时间线滚动恢复失败，原始日志和附件保留 |
| `ios-build04` / `ios-tests03` | 构建成功；当轮旧输入实现的默认字号宿主基线 **26/26** | ChatRenderer 10、Markdown 渲染 1、ModelRecovery 7、Provider 深浅色渲染 1、日期 4、时间线阅读 3；包含真实滚动、销毁重建和追加正文后的原严格位置验证，不覆盖后来的输入框候选和首页 Avatar 改动 |
| `summary-tests-01` | 配置摘要 **2/2**，runner `accepted=true` | 正式 Pi / ProviderConnection 经受控 HTTPS 完成成功与 503 两条路径；宿主已停止，两个新隔离工作目录已清理；不使用公网或付费模型 |
| `http-runner-selftests-01` | **5/5** | runner 的测试入口及执行控制自检，不计为产品 UI 或模型质量验收 |
| `release-verifier-selftests-01` | **17/17** | Release 检查器自检，与下面实际产物检查分别记录；不证明安装或运行行为 |
| `Release01` | `BUILD SUCCEEDED`；静态检查 **19/19**，0 错误；`codesign --verify --deep --strict` 退出 0 | 手机与嵌入 Watch 的身份、固定模型哈希、声明、Debug 入口及 fixture 排除通过；签名有效；随后在同一台专用 iPhone 安装、无测试启动参数打开首次体验并进入首页，通过普通启动检查 |
| `ios-ui-tests-01` | 默认字号 App UI **6 通过、1 失败** | 普通 Composer 导航 1、时间线 4、Watch 静音状态 1 通过；硬件 Shift+Return 未产生要求的换行，仍为 `AB`，该失败未关闭 |
| `ios-ui-tests-06` | App UI **3 通过、1 失败** | 首字前取消、普通 Composer 导航、抽屉新会话保留草稿通过；硬件键盘用例未达到精确多行文本与稳定输入框断言 |
| `ios-ui-tests-08` | **4 通过、1 失败**，其中 App UI 3/4、宿主 WK 1/1 | 三项通过的 App UI 路径与 06 相同，另有聊天渲染器头像外观/隐藏/减弱动态效果用例通过；硬件键盘用例仍失败，不把该 WK 用例等同于首页动效完整验收 |
| `ios-ui-tests-09` | 硬件键盘单项 **0/1** | 失败发生在系统键盘切换入口前置条件，未能明确选择 English (US)；不能算作已经执行换行后的结果 |
| `ios-ui-tests-10` | 硬件键盘单项 **0/1** | 精确多行文本与稳定输入框断言失败，测试用时 58.521 秒；原失败记录保留 |
| `ios-ui-tests-11` | 硬件键盘单项 **0/1** | 同一精确多行断言仍失败，测试用时 45.666 秒；不据此推定 Apple 内部派发或文本实现的确定根因 |
| `ios-build14` / 原始 SwiftUI 实际输入观察 | 构建成功；实际 Shift+Return 得到并持久保存精确 `A\nB` | 恢复 main 原始 SwiftUI `TextField` 后，通过 DeviceHub CaptureKeyboard 直接操作；关闭隔离 fixture 后独立检查仅有 Persona 初始化，无 Pi 会话、会话元数据或持久数据库，不等于六行/七行、中文 IME 或完整硬件诊断用例通过 |
| `ios-build15` / `default-finaltest01` | 构建成功；**33 通过、0 失败、1 明确跳过**，结果中无 runtime warnings | 当前原始 SwiftUI 输入与 main Avatar 源码上的 ChatRenderer 10、MarkdownReading 9、ModelRecovery 7、日期 4，共 30 项宿主测试，加 3 项 App UI；硬件键盘诊断默认显式跳过，不算通过；Provider、Timeline 的目标名称不匹配，执行数为 0 |

用户于 2026-10-16 要求移除所有大字号测试，删除和 [AGENTS 规则](../../AGENTS.md#测试字号约定) 已提交，明确覆盖旧 HANDOFF 和验收矩阵；不是待办。大字号专用用例、放大分支和专用参数已移除，混合业务用例保留默认字号验证；VoiceOver、减弱动态效果与默认字号的对比度检查继续保留。历史测试结果和截图不改写。

按当前源码逐项计数并由 `watch-tests04` 实跑确认，Watch 为**19 项原生测试与 2 项 UI，共 21 项**：`WatchMicrophoneGateTests` 5、`WatchCaptureReliabilityTests` 5、`WatchNativeCaptureTests` 9、`WatchCaptureJourneyTests` 2。其中包含容量预检与真实输入后开片拒绝的两项原因保留验证，以及从 main 同步的两个自动同步原生用例和一个同步说明 UI 用例。同步原生用例验证正式账本和受控传输边界，不是物理 WatchConnectivity 投递；历史 19/19 与当前 21/21 分别保留。

以上轮次不能相加为一次完整回归。当前原始记录位于本机 `tmp_agent_output/watch-reliability-20261016/`，对应 `watch-tests-04-summary.json`、`watch-tests-04.xcresult`、`ios-summary-03.json`、`summary-tests-01/run.json`、`summary-tests-01/summary.json`、`ios-ui-summary-01.json` 及各同轮日志。下方有界 Watch 证据与当前测试摘要来自 `watch-tests04`；旧轮次的原始记录继续保留。

`default-finaltest01` 已在单台 iPhone 模拟器完成，原始摘要为 `tmp_agent_output/watch-reliability-20261016/ios-final-summary-01.json`：总计 34 项，其中 33 通过、0 失败、1 明确跳过，`runtimeWarnings` 为空。它使用 `ios-build15` 编译的当前原始 SwiftUI 输入及 main Avatar 源码；实际通过的是 ChatRenderer 全部 10 项、MarkdownReading 全部 9 项、ModelRecovery 7 项、日期 4 项，共 30 项宿主测试，以及 3 项 App UI。硬件键盘诊断默认跳过，未执行其严格断言。Provider 与 Timeline 的目标名称不匹配，本轮执行数为 0，旧轮通过证据仍分别保留；不把历史 26/26 改写为当前全部重新通过。

最终 [Release 静态检查报告](evidence/2026-10-16-capture-reliability/release-bundle.json)为 `passed`，19 项检查全部为真、`errors` 为空，四份模型资源与固定哈希一致；[签名验证日志](evidence/2026-10-16-capture-reliability/release-signature.log)记录产物 `valid on disk` 且满足 Designated Requirement。静态报告本身不验证代码签名，后者由独立严格签名命令补充；随后完成独立的[安装与普通启动检查](evidence/2026-10-16-capture-reliability/release-install.json)：安装后主程序 SHA-256 与已审计的 Release 完全一致，无测试环境覆盖或启动参数，实际看到首次体验并点击“开始使用”进入[首页](evidence/2026-10-16-capture-reliability/release-home.png)。这不验证 Watch 安装、真机或 App Store 分发。

原生证据进一步限定如下：

- [输入路由与准入](evidence/2026-10-16-capture-reliability/watch-input-route.json)：实际路由为 `builtInMic`、`categoryOptions = 0`、输入 48 kHz；收到 1 个真实 tap / 4,800 帧时，受控关闭的准入门交付 PCM 为 0。此用例没有切换物理耳机。
- [媒体重置恢复](evidence/2026-10-16-capture-reliability/watch-media-reset.json)：向正式处理入口注入受控重置事件，前后两个 epoch 均真实采样并保留原音；暂停后的迟到事件未重启采集。它没有触发操作系统真实 media-services reset。
- [诊断写入故障](evidence/2026-10-16-capture-reliability/watch-diagnostic-fault.json)：SQLite 触发器造成诊断插入失败，仍封口 17,600 帧并保留带哈希的音频文件。
- [容量预检拒绝](evidence/2026-10-16-capture-reliability/watch-preflight-capacity.json)：受控可用空间为 1 字节，正式启动预检拒绝后没有创建音频或采集事件；可见原因保留 `lowSpace`，成功清理追加 `finalized`，同库新运行时仍保留原因。
- [真实输入后的开片容量拒绝](evidence/2026-10-16-capture-reliability/watch-native-capacity.json)：预检先通过，收到 1 个真实 tap / 4,800 帧后，正式编码器首次开片的第二次容量检查拒绝；未创建 AAC 文件，账本保留一个 epoch 中断。可见原因为 `lowSpace`，收尾为 `finalized`，原容量错误仍报告，未误标 `cleanupFailed`。
- [原生采样账本](evidence/2026-10-16-capture-reliability/watch-native-ledger.json)：真实采集 1,094,400 帧（16 kHz），跨过默认 60 秒 AAC 边界，包含标记、暂停、恢复、停止与重开；共 2 个 epoch、1 个标记、3 个未确认原音文件，核对帧区间和哈希。此用例实际耗时 69.4736 秒，未发送 WatchConnectivity 业务确认。

[测试摘要](evidence/2026-10-16-capture-reliability/watch-tests-summary.json)保存当前 21/21 结果；[开始](evidence/2026-10-16-capture-reliability/watch-start.png)、[录音](evidence/2026-10-16-capture-reliability/watch-recording.png)、[暂停](evidence/2026-10-16-capture-reliability/watch-paused.png)为 `watch-tests04` 的真实模拟器截图。[证据索引](evidence/2026-10-16-capture-reliability/evidence-index.json)已按当前有界证据统一重算大小和 SHA-256；索引不包含自身。原始失败日志继续保留，不以新结果覆盖。

## iPhone 配套改动

[日期范围模型](../../Apps/iPhoneApp/Features/Library/TimelineModel.swift)区分尚未加载、已确认无历史与已知边界；读取失败可以重试，不用猜测日期开放无限历史。DST 回拨的同名时刻使用录音记录的 UTC 偏移消歧，绝对时间和归组身份不变。

[时间线问题展示](../../Apps/iPhoneApp/Features/RecordingDetail/TimelineIssuePresentation.swift)保留已完成正文，区分真实缺片、待处理与具体失败范围。局部重试使用当前窗口 revision、来源 generation 和所选问题范围校验，不能扩大为整窗重做；运行时 `failureScope` 仅对应本次实际失败，不伪装成重启后仍存在的持久失败。

`ios-tests02` 暴露了混排后的滚动目标身份不一致：顶层 `ForEach` 使用 `.paragraph(UUID)`，恢复命令仍使用裸 UUID，段落没有被恢复挂载。已统一 `ScrollPosition` 初始化、重置及 `scrollTo` 的顶层身份；持久锚点仍是原段 UUID，问题卡使用独立稳定 ID。未改原来的可读高度、版本准入、稳定采样和追加位置断言；`ios-tests03` 的三个时间线阅读用例全部通过。

[已配置摘要集成测试](../../Tests/iPhoneIntegrationTests/TimelineConfiguredSummaryTests.swift)通过正式保存的 ProviderConnection、PiAgentHost、Archive 和 TimelineModel 访问受控本地 HTTPS，使用合成凭据，不访问公网或付费模型。`summary-tests-01` 已实际通过成功、缓存重开不再请求、来源修订拒绝旧缓存及 503 保留原稿和原音两项测试；没有削弱隔离聊天网络限制。这是受控响应下的配置、请求和存储闭环，不是外部模型摘要质量验收。

硬件键盘调查中曾引入原生 `UITextView` 输入候选，其相关构建已成功，并在 CUA 实际系统输入路径、English (US) 键盘下观察到两行 `a\nb`。该约 200 行候选现已移除，`AssistantView` 已恢复为与 main 一致的原始 SwiftUI `TextField`，`ios-build14` 构建成功。随后通过 DeviceHub CaptureKeyboard 直接执行 Shift+Return，实际得到精确的 `A\nB`；关闭隔离 fixture 后独立读取持久草稿，仍为这两行，Agent 目录仅有 Persona 初始化，会话数、会话元数据数、持久数据库数与用户请求数均为 0。详见[原始 SwiftUI 两行输入观察](evidence/2026-10-16-capture-reliability/original-swiftui-two-lines.json)。这证明本次直接操作的换行与保存，没有证明六行到七行的高度上限、重启后完整交互或中文输入法，也未检查整机网络流量。

严格的 [XCTest 硬件键盘诊断](../../Tests/AppUITests/PhoneComposerHardwareKeyboardTests.swift)保留全部断言，现需在测试 runner 环境显式设置 `MOMO_RUN_HARDWARE_KEYBOARD_DIAGNOSTIC=1` 才执行；默认通过 `XCTSkipUnless` 明确跳过，跳过不计为硬件键盘通过。这一区分保留了 Xcode 27 自动派发路径与实际 DeviceHub 输入观察的差异，不推定 Apple 内部原因。原 hosting 候选及 01/06/08/09/10/11 自动测试失败继续保留。实际输入观察结束后曾关闭全部模拟器，Release 构建没有启动模拟器；随后仅启动一台 iPhone 执行上述最终默认测试与 Release 普通启动检查。全部结束后已停止 App、关闭设备并删除本轮自建的 `53EAE745-D38F-41A4-A226-39E0C0923C6F` 专用模拟器，连同其中的临时 CA 与合成测试资料一并清理；既有 iPhone/Watch 设备保留并关闭。当前运行设备为 0，没有本任务构建、测试、HTTPS 服务或供音进程。

## 尚未验证的边界

- 本轮无可用物理 Watch；耳机真实切换、真实系统重置、熄屏及 18 小时持续采集、配对传输和续航仍需设备验证。模拟器恢复用例不能替代这些结论。
- 最终 Release 构建、实际产物 19/19 检查与严格签名验证已完成；安装与普通启动检查也已通过。当前 Watch **19 原生 + 2 UI** 已完成模拟器复测，不再列为待办。
- 硬件键盘完整验收仍未完成：01 的 `AB`、09 的系统键盘前置失败以及 06/08/10/11 的精确多行断言失败分别保留。当前 main 原始 SwiftUI 输入实现已经直接观察并持久保存 `A\nB`，且该隔离 fixture 无 Pi 会话或用户请求；六行/七行高度边界、重启后完整交互及中文 IME 仍待验证。严格 XCTest 诊断默认显式跳过，不能作为通过证据；两行硬件换行也不能替代中文组合输入验收。
- 后续包测试受依赖下载 TLS 错误阻止，尚无最终源码的全包通过结论；既有 `package03` 定向结果仅代表当轮。
- 聊天开始、完成、停止、中断的真实 VoiceOver 播报尚未验收。DOM 的 `aria-live` 文本和 `currentSpeech()` 焦点朗读均不能替代实际异步播报证据。
- 深色 Settings 的既有系统可访问性审计风险仍保留；本轮未验证其已消除，也未把默认字号决定当作删除 VoiceOver、对比度、窄屏或 Reduce Motion 要求。
