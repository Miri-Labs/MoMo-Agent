# Watch Simulator 0 Hz 输入诊断

2026-10-14，Xcode 27.0 / 27A266a，macOS 26.6.2，watchOS 27.0 / 24R362，专用 SE3 44 mm Simulator。**截至 22:25，最终视觉版本的完整 UI 旅程通过；两项原生采样沿用 21:46 完整三项基线中完全相同音频源码的通过证据。** 下文按阶段保留原始 0 Hz、零帧、崩溃和 UI 失败记录。该结论是 SE3 模拟器软件验收，不能替代目标 SE2 真机、腕部输入、后台、续航或 WatchConnectivity 验收。

## 最新正式验收

### 22:25 最终视觉版本的 UI 复验

`tmp_agent_output/20261014-watch-blackhole-e2e-06/` 的 build06 成功，`CaptureView.swift` 为 `f2af669827de9fa6fe7374e41e287fd853f57c2b0cda12b7c5d2d22893ce928a`。先以正式 App、独立 run UUID、相同公开 BlackHole 输入做实际预览：第二次录得 208,000 帧/16 kHz，即 13 秒，正常暂停封口、结束确认后退出。音频实际 SHA/字节数与 manifest 相符，原音已清理。第一次预览因初次 CUA 选择/缩放及转换页面检查耗时，在 90 秒外层期限前未完成结束确认；该失败独立保留并完成兜底清理，不称为正常停止。

主任务与视觉审查者读取真实预览图确认布局后，只执行最后一次完整 UI 旅程：**1 通过、0 失败、0 跳过、无 runtime warning**，用例 109.423 秒，原 120 秒期限不变。51 项构建输入从 build06 到两次预览和 UI 结束都保持同一哈希。相对 `final-01` 只有显示层 `CaptureView.swift` 改变；两项原生采样沿用其未改音频/运行时/测试源哈希证据，本轮未重跑 65 秒采样，不能把跨轮证据合成“新三项通过”。

`ui/review/` 七张实际截图均已读取：近全宽方形点距、白色有声点及灰色背景点清楚，时钟、工具栏和底部按钮文字完整；状态、更多和原生结束确认正确，重启前后仍为两片/38 秒待确认。这里确认参考图的主要视觉层级，不声称像素完全一致。`stage-results.json`、`inherited-native-evidence.json` 和 `manual-visual-review.json` 分别保存结果、跨轮源哈希关联和逐图观察。两个预览及 UI 的独立原音目录均已移除，宿主、播放器与日志进程已停止；未改 Mac 默认音频路由。

### 22:10 点阵视觉修补后的定向复验

`tmp_agent_output/20261014-watch-blackhole-e2e-05/` 重新构建后，仅执行完整 UI 旅程：**1 通过、0 失败、0 跳过、无 runtime warning**。用例 109.724 秒，仍使用既定 120 秒期限；构建前至测试后的 51 个输入哈希稳定。与 `final-01` 相比只有 `CaptureView.swift` 改变，两个原生采样用例沿用下述未改音频/运行时/测试源哈希的通过证据，本轮没有重新执行 65 秒采样。

七张实际截图已逐张读取，点距为正方形，真实 RMS 没有此前放大后饱和的外观，状态、按钮、更多、结束确认均可操作；重启前后仍为两片、38 秒待确认。实图点阵约占 448 像素屏高的 28%，不能称为参考图 46% 比例已完全一致。源哈希关联、截图 SHA、视觉观察分别在 `inherited-native-evidence.json`、`stage-results.json`、`manual-visual-review.json`。本轮新增原音目录已记录 SHA 后删除，宿主、播放器与日志进程均结束。

### 21:46 完整三项基线

证据目录 `tmp_agent_output/20261014-watch-blackhole-final-01/` 复用 `20261014-watch-blackhole-e2e-04` 冻结构建。三项命名用例各执行一次、串行生成三个全新 xcresult，**3 通过、0 失败、0 跳过**，各自 runtimeWarnings 为空；51 个相关源文件从 build04 到最终测试结束哈希相同。此前 `e2e-02/03` 的 UI 失败不计入该轮通过数，原证据不覆盖。

- 最短实际采样、标记、暂停、重新创建 runtime：通过；恢复封口时长和原音，不自动重新开麦克风。
- 默认 60 秒 AAC 分片及恢复：实际 1,096,000 个 16 kHz 帧，即 68.5 秒；三片为 60 秒、5.2 秒尾段和恢复后的 3.3 秒，两个 epoch、一次标记。哈希、字节数、AAC 解码、连续帧区间、epoch 终点、账本重开与无确认原音保留全部通过。停止宿主后的独立解码平均音量为 -20.7/-20.5/-21.7 dB，三个 SHA 与测试附件一致。
- 按用户新参考布局的 UI 旅程：通过。实际打开详情查看时长并显式关闭，主画面开始/标记/“静音”暂停、重启恢复、继续、“更多”结束确认、再次重启均走通；两次详情均为 2 片原音、38 秒待确认。UI 测试 111.318 秒，在既定 120 秒期限内，没有放宽时限。

`stage-results.json` 汇总原始结果、构建来源、源哈希、AAC 统计和截图 SHA。`ui/review/` 的七张真实截图已逐张读取：主界面深色背景、奶油色桌面/更多图标和时钟清楚可见；真实 RMS 点阵有响应，底部按钮及标签完整；暂停/停止状态准确，更多列表、原生结束确认及详情均可读。测试验证实际可见的元素，未使用隐藏时长、任取 firstMatch 或跳过确认。

各阶段的 App、播放器与日志进程均结束，停止宿主后只清理本轮新增 UUID 目录并保存文件大小/SHA，三个隔离原音 run 全部移除；未导出声音。使用的是同一公开 fixture 经 BlackHole → 原生 AVAudioEngine → 正式 AAC/账本链路，不声称物理麦克风或模拟器 WC 文件投递通过。

## 宿主授权后的新结果

独立探针增加 `AVAudioRecorder` 对照，使用 Apple SDK 支持的三秒 mono PCM/WAV 临时录音。逐阶段报告、关闭后按块解码的帧数/RMS 和外层清理独立保存；所有临时 WAV 均已删除，没有复制或上传原音。两种 API 使用独立进程，不共享 engine。Recorder 的实际结果不能替代产品的 Engine 采集验收。

| 证据目录（`tmp_agent_output/`） | 实际观察 |
| --- | --- |
| `20261014-watch-recorder-probe-03` | guest 已允许、session 48 kHz，但 `prepareToRecord` 90 秒内未返回。host TCC 真正进入 `AUTHREQ_PROMPTING` / `display_prompt`，subject 为 SimulatorTrampoline。外层终止 App 并删除临时 WAV，未记为录音完成。 |
| `20261014-watch-recorder-probe-04` | 用户亲自允许系统麦克风提示后，host 日志明确 `Allowed (User Consent)`；prepare 返回 true，record 返回 false。实际 WAV 0 帧、48 kHz、RMS 0，1.407 秒失败并正常去激活/清理。 |
| `20261014-phone-recorder-probe-01` | 同一 Sources 的独立 iPhone target、AC2 专用诊断 bundle，prepare true / record false / 0 帧，1.364 秒失败并清理。与 Watch 同现象，不能说只发生于 Watch。 |
| `20261014-watch-engine-authorized-01` | 手动启动路径未取得终态 JSON，外层超时，不能据此判断 Engine 格式或采样结果。 |
| `20261014-watch-engine-authorized-02` / `-03` | 显式 CLI 启动后 App 在约 2.8 秒发生 SIGTRAP；未生成终态报告。第一轮完整 lifecycle 日志证明 App 退出时间早于 iPhone Recorder 开始，不存在两个探针同时采集。 |
| `20261014-watch-engine-stack-02` | LLDB 25 秒有界运行取得完整崩溃栈：RealtimeMessenger 队列 → `_dispatch_assert_queue_fail` → `_swift_task_checkIsolatedSwift` → `CaptureProbe.run` 的 tap closure → `AVAudioNodeTap::TapMessage`。这确证探针回调继承了 MainActor 隔离，并已收到一次 tap 调用；不能据此推断该次 buffer 含正数帧。 |
| `20261014-watch-engine-sendable-01` | 只把 tap closure 标为 `@Sendable` 后重新构建，源哈希前后一致。新进程硬件与 tap 格式为 24 kHz / 1 channel，`engineStarted=true`，3 秒计数 0 帧，状态 `failed_no_frames`，无 SIGTRAP，正常去激活。没有写原音。 |

Recorder 两端日志均有 AudioQueue start `-66681`；本机 SDK `AudioQueue.h` 定义其为 `kAudioQueueErr_CannotStart`。Watch 还记录了 `reconfig pending` 和 20 次未见 I/O cycle。实际 AirPods 输入会进入 24 kHz 模式，而 session 属性仍报 48 kHz；日志中存在重采样 converter。采样率差异本身不能当成失败根因，也不能强制虚构 tap 格式来绕过硬件状态。

该阶段没有重启 CoreSimulator、Device Hub 或 coreaudiod，没有配对/抹除设备、改全局音频输入或 TCC 数据库。系统授权提示由用户亲自处理；自动化工具拒绝访问 UserNotificationCenter，未绕过该限制。正常系统设置只读观察不替代 host TCC 的允许证据。

该阶段尚待正式 Watch 用例验证实际采样、封口、暂停恢复和 UI。独立工具另补了 `tapCallbacks` / `emptyTapCallbacks` 次数统计，在 `20261014-capture-probe-counters-build-01` 以原独立 DerivedData、`-jobs 1` 顺序构建 Watch 与 iPhone 两个 target，全部成功、源码前后哈希一致。**该轮只编译，未启动设备或录音**；不能追溯解释 `sendable-01` 的 callback 数量。后来实际通过的结果见文首。

## 重启后的受控虚拟输入复测

BlackHole 2ch 0.7.1 官方签名安装包已经安装成功，安装器要求重新启动 Mac。安装后 `tmp_agent_output/20261014-virtual-audio-01/audio-after-install.json` 尚未枚举到 BlackHole；这份安装时证据本身不证明驱动已可用。用户后来于 20:13:32 重启，新的 AudioDevice 枚举已确认 BlackHole 48 kHz 双向设备加载。

重启后先确认 `BlackHole 2ch` 确实出现在 AudioDevice 列表。仅为 Device Hub 中的专用 Watch `84B7054F-7749-4688-B703-896DA4FBA7D3` 选择 Device → Sound → Sound Input → BlackHole 2ch；不改 Mac 全局输入或输出默认值。使用进程级 `SDL_AUDIO_DEVICE_NAME='BlackHole 2ch'` 的 ffplay 将既有公开 fixture 定向送入虚拟设备，执行示例见[探针 README](../../Tools/WatchCaptureProbe/README.md#受控虚拟输入)。设备缺失或实际输出路由未核实时停止，不回落到默认扬声器并声称配置正确。

输入为 `tmp_agent_output/20261014-virtual-audio-01/zh-loop-90s.wav`，实检 48 kHz、双声道、16-bit、4,320,000 帧、90 秒，SHA-256 `31a4c94106ccfd8714bcfb060e05159083ad1e621fa8bb7716836a25f66559b4`；这是同一公开样本重复的压力输入，不计入新的中文质量语料。先运行三秒 Engine 探针，记录实际帧数、RMS、callback/空 buffer 数、实际硬件/tap 格式与路由。正数帧和已知非静音输入的有效 RMS 得到确认后，才依次运行正式 Watch 最短暂停恢复用例、65 秒 AAC 边界用例及 UI 旅程；每轮采用新的证据目录和有界播放进程，完成后停止播放器、测试宿主并核对临时文件清理。

该流程验证公开 fixture → 虚拟 CoreAudio 输入 → Simulator 原生采集 → 正式文件/状态链路，必须标为**受控虚拟输入**。它不证明 AirPods/Watch 物理麦克风、腕部录音质量、真实佩戴或续航。旧失败继续保留。

20:13 重启后的 `20261014-watch-blackhole-probe-01` 独立 Engine 探针，以同步 `setActive(true)` 取得 144,000 真实帧、48 kHz/2 channel、30 次 tap callback/0 次空 callback、RMS 0.1046247，正常去激活。`simctl io enumerate` 明确 guest 输入为 `BlackHole2ch_UID`，公开输入哈希相符；三秒输入没有落盘，播放、日志、探针均已停止。系统输出默认值在前后观测中由 AirPods 变成 Mac mini 扬声器，任务没有调用全局路由设置或选择输出，原因未判定；输入默认仍为 AirPods。该背景变量如实保留在 `default-route-check.json`，不回写用户选择。

随后正式 Watch 新配色/图标及显式 `@Sendable` tap 版本在 `20261014-watch-blackhole-e2e-01` 构建成功，51 个输入文件哈希前后一致。但最短暂停恢复用例 0/1 通过，1.462 秒原始 `unsupportedInput`；它仍使用异步 session activation。失败后的全新 engine 在立即、200 ms、1 s 都是 0 Hz，未进入三秒输入或暂停/恢复断言。65 秒及 UI 用例当时没有执行。安装重建期间 App 数据容器路径变化，收尾重新解析当前容器，只删除本轮新增 run UUID；补充清理证据为 `short/container-change-cleanup.json`。

为隔离 activation API，独立工具增加显式 `--async-activation`，其异步实现与正式链路相同，并在两种路径中都只在 activation 完成后创建新 engine。本机 `AVAudioSession.h` 声明同步 `setActive` 支持 watchOS 2+，异步 `activate(options:completion:)` 支持 watchOS 5+；异步回调语义是激活完成或失败后调用。两个 API 都受支持，未强造硬件格式。

| 同一冻结探针二进制的新进程 A/B | 同步 `setActive(true)` | 异步 `activate(options:completion:)` |
| --- | --- | --- |
| 证据 | `20261014-watch-activation-sync-01` | `20261014-watch-activation-async-01` |
| activation | 成功 | completion 返回 active 成功 |
| fresh engine 硬件格式 | 48 kHz / 2 channel | 0 Hz / 0 channel |
| 真实帧 / tap callback / 空 callback | 144,000 / 30 / 0 | 0 / 0 / 0 |
| RMS / 终态 | 0.070857 / `captured_real_input_frames` | 0 / `zeroInputFormat` |

两轮同一专用 Watch、明确 BlackHole guest 路由、同哈希公开输入，分别新进程顺序运行；播放器有界并全部清理。`20261014-watch-activation-ab-01` 保存源码哈希稳定的构建证据。该对照支持当前 runtime/路由下的激活 API 差异，不能泛化为全部 watchOS 的异步 API 缺陷。

据此正式 `WatchAudioSession` 改为在专用串行后台队列调用官方同步 `setCategory(.record, .default)` 与 `setActive(true)`，原始系统错误传回等待者；去激活也在同队列执行并被 `await`。队列回调显式 `@Sendable`，只捕获 continuation。`WatchRuntime` 的 activation 后 generation 检查、停止时先等待 startup/encoder/封口、最后完成去激活的屏障保留，没有超时 fallback、固定采样率、合成输入或忽略错误。新的正式三项结果必须独立验证后记录，不能用探针成功替代。

修补版 `20261014-watch-blackhole-e2e-02` 构建成功，51 个相关输入哈希稳定。两个原生用例分别通过：最短实际采样/标记/暂停/重建 runtime 为 4.654 秒；分片用例实际采集 1,092,800 个 16 kHz 帧（68.3 秒），两个 epoch、一次标记、三片原音，帧数分别为 960,000、83,200、49,600，即 60 秒默认边界、5.2 秒尾段及恢复后的 3.1 秒。AAC 解码、SHA-256、字节数、连续帧覆盖、结束事件、重开账本和无接收确认时原音保留断言都通过。停止宿主后额外逐片解码量测为 -20.7/-20.8/-23.9 dB 平均音量，三片 SHA 与 XCTest 一致；仅保存统计并清除本轮隔离原音，未导出声音。

同版 UI 首轮已完成开始、标记、暂停、进程重启恢复和再次采样，但停止按钮查询因 watchOS 工具栏的父/子 Button 同时继承 `capture.stop` 标识而失败。完整层级显示两节点同位置、同标签；传输按钮也是同结构。没有执行后续停止确认和原音保留检查，不能宣布 UI 通过。修正仅将工具栏测试查询限定为 `navigationBars.children(matching: .button)` 下的唯一标识，不使用任取 firstMatch，不改变产品或放宽状态断言；待新构建复测。底层音频日志仍有 reconfiguration/stop 文字，但两项原生 xcresult 的 runtimeWarnings 为空，不把这描述为系统日志完全无警告。

`20261014-watch-blackhole-e2e-03` 纳入固定 Watch 深色 palette 后再次构建，编译前后 51 项哈希一致。两项原生测试再次通过，边界录到 1,096,000 帧（68.5 秒，60+5.3+3.2 秒三片）。UI 已成功点击工具栏停止按钮并显示真实确认页，但系统 `confirmationDialog` 将动作暴露为 Table 内的“结束录音”按钮，没有传递 SwiftUI 的 `capture.confirmStop` 标识，故该轮仍失败。已按实际层级将测试改为等待确认页标题、再点击表内唯一动作，未改变停止逻辑或放宽后续断言。该轮暂停截图确认深底、时钟和正文正常，但两个工具栏图标与圆底同为奶油色、对比不足，仍需局部视觉修正。全部新增隔离 run 的原音已在宿主停止后清理，日志和失败截图保留。编译后共享 palette 仅注释措辞变化另被记录，不把本轮称为全程所有源码字节不变。

## 新一轮结果

本轮独立证据目录为 `tmp_agent_output/20261014-watch-input-diagnostics-01/`，内含全新 `DerivedData`、`build.xcresult`、`tests.xcresult`、summary、原始日志和 JSON 附件。只复用固定依赖源码/下载缓存，不复用旧测试产物。

- `build-for-testing` 成功，`-jobs 1`。
- `WatchNativeCaptureTests/testPausedRuntimeRestoresSealedDurationWithoutRestartingMicrophone`：0 通过、1 失败、0 跳过，1.515 秒，以原始 `unsupportedInput` 结束。未到达 3 秒采样、暂停或恢复断言。
- 未重跑其余两个长用例；先前默认输入和显式 AirPods 输入的失败记录继续保留在 `tmp_agent_output/resume-20261014-syh/watch-e2e-20261014-165845/`。
- 本轮没有改产品采集路径、主机 TCC、全局音频输入、系统信任或 Simulator 服务，也没有使用合成采样。测试结束后专用 Watch 已关闭；主 iPhone 未改动。

## 已观察到的边界

附件中的 guest `recordPermission` 为 `1735552628`（SDK 的 `'grnt'`），`AVAudioSession` 为 `.record/.default`、48 kHz、`inputAvailable=true`、`inputNumberOfChannels=1`，route input 为 `MicrophoneBuiltIn`。但 port 的 channels 数组为空；该名称不能证明 Mac 物理麦克风已成功映射。

正式启动失败后，全新 `AVAudioEngine` 在立即、200 ms、1 s 三次查询均报告硬件 input format 为 0 channel / 0 Hz，output format 为 2 channels / 0 Hz。没有收到 route change、interruption、media-services reset/lost 通知。这削弱了“仅旧 engine 提前创建、缓存一次格式”或“等 200 ms 就会恢复”的解释；探针仍处于同进程、同共享 session，不能外推所有初始化行为都正确。

guest 日志先报告 `AVAudioIONodeImpl` 关联 audio session `(0x0)` 时 `-10879`，随后 `AURemoteIO` 报 `-10851` 和 0 Hz。当前 SDK `AUComponent.h` 分别定义为 `kAudioUnitErr_InvalidProperty`、`kAudioUnitErr_InvalidPropertyValue`；两者都不是专门的权限拒绝错误。正式 `AudioCaptureEngine` 在 `installTap`、`prepare`、`start` 之前检测并拒绝这个格式，没有靠修改采样率绕过检查。

## 宿主授权归属与 UI 对照

`host-audio.log` 中，与测试 App PID 43305 对应的 microphone 查询 `msgID=507.790` 是 **preflight**。responsible/subject 为 `com.apple.CoreSimulator.SimulatorTrampoline`，返回 `authValue=1`，并明确包含 `preflight_unknown=true`。同一 App 的 guest TCC 为 `Allowed / System Set`。这是宿主授权归属尚未确定的线索，不能写成“用户拒绝麦克风”。

随后宿主有 `SimulatorTrampoline.xpc` 的 `LSApplicationRecord` 创建失败 `-10811`，但该行没有关联查询 ID，且位于额外 ScreenCapture/AudioCapture 查询之后；不能把它严格绑定为麦克风失败原因，也不能盲目向 LaunchServices 注册这个系统 XPC。

另外从 Device Hub 的 Watch 主屏图标打开正式 App，手动点击开始（PID 44439），界面仍为 `0:00:00`、录音已停止。guest 再现 `-10879` → `-10851`，宿主 microphone 查询 `msgID=507.808` 仍归属同一个 SimulatorTrampoline，仍为 `preflight_unknown=true`。没有出现可操作的宿主麦克风授权弹窗；`ui-host-audio.log`、`ui-guest-audio.log` 保留完整对照。UI 启动没有改变此次归属。

## 升级后服务核对

| 项目 | 当前路径或启动时间（Asia/Shanghai） |
| --- | --- |
| Xcode.app 更新 | 16:35:46，`/Applications/Xcode.app` |
| CoreSimulator framework 更新 | 16:39:58，`/Library/Developer/PrivateFrameworks/CoreSimulator.framework`，1171.7 |
| CoreSimulatorService PID 20456 | 16:42:44，当前 framework 内 XPC |
| SimulatorTrampoline PID 20458 | 16:42:45，当前 framework 内 XPC |
| SimAudioProcessorService PID 23093 | 16:54:22，当前 framework 的 audio service |
| Device Hub PID 26807 | 17:09:09，`/Applications/Xcode.app/Contents/Applications/DeviceHub.app` |
| Device Hub LaunchServices | 同一当前路径，27.0 / 255.2.6，16:51 注册 |

进程均晚于升级；没有“旧服务仍在运行”证据，因此本轮没有重启整个 CoreSimulatorService。Device Hub 最低系统为 macOS 26.6，本机 26.6.2 满足它，不能据此归因于系统版本不满足要求。

## 官方资料及下一步

Apple 的 `AVAudioEngine.inputNode` 文档要求检查非零硬件采样率和声道数来判断输入是否启用。本轮 0 Hz 足以证明输入不可用，但不能区分宿主权限、模拟器桥接和 App 初始化原因。[Apple inputNode 文档](https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode)

Device Hub 官方文档提供 Device → Sound → Sound Input，System 使用 Mac 默认输入，也可选择其他输入。切换蓝牙耳机输入可能改变设备音频模式；本轮没有修改全局输入。[Apple 模拟设备环境配置](https://developer.apple.com/documentation/xcode/configuring-the-environment-of-a-simulated-device?language=objc)

读取完整 Xcode 27 / watchOS 27 release notes 后，没有找到“watchOS 27 Simulator 不支持麦克风”说明。Xcode 27 已知音频限制之一是 Sound Input/Output 不能设为 None；这不足以解释本次故障。文档没有列出问题，也不证明平台没有缺陷。[Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)、[watchOS 27 release notes](https://developer.apple.com/documentation/watchos-release-notes/watchos-27-release-notes)

需要验证真实麦克风帧数，不能把读取到 48 kHz、合成音频或 Apple API 返回成功作为采集通过。不要修改 TCC 数据库、盲目重注册系统组件或降级 runtime 来掩盖失败。后续可整理最小复现和环境证据向 Apple Feedback 报告；尚未提交 Feedback。

## 独立 Apple API 最小复现

随后按用户授权执行 [WatchCaptureProbe](../../Tools/WatchCaptureProbe/README.md)，证据为 `tmp_agent_output/20261014-watch-minimal-probe-01/`。它是独立 watch-only 工程、独立 bundle ID，只用 Apple 框架，不链接任何产品模块。先 `.record/.default`、同步 `setActive(true)`，再创建一个全新 engine，且只获取一次 `inputNode`。非零格式才安装 tap 并采集三秒，只计帧和 RMS，不保存声音。

首次构建成功，但安装器拒绝了诊断工程同时声明 `WKWatchOnly` 和 `WKRunsIndependentlyOfCompanionApp` 的配置。仅删除诊断工程中后一互斥字段后，第二次构建、安装与启动均成功，原失败记录保留。未改产品工程。

18:49 的唯一输入尝试中，guest 出现了真正的首次麦克风弹窗并选择允许：guest TCC `msgID=55647.2` 为 `authValue=2 / authReason=2`（User Set）。PID 55647 的独立 App 记录 session 激活成功、48 kHz、1 input channel；engine 的 hardware input 仍是 0 channel / 0 Hz，tap output 仍是 2 channels / 0 Hz。结果为 `zeroInputFormat`，0 帧，没有进入 tap/start 或三秒采集。报告的 9.66 秒包含等待权限交互，不能当作实际采样时长。

同时间 host microphone 查询 `msgID=507.859` 指向 PID 55647，但 responsible/subject 仍是 SimulatorTrampoline PID 20458，`preflight_unknown=true`；没有出现宿主麦克风弹窗。这仍不是用户拒权的证据。guest 继续出现 audio session `(0x0)` 关联 `-10879`、AURemoteIO `-10851`。711 行 guest 日志、17,792 行 host 日志、权限弹窗和结果截图、统计 JSON 均已保存；App 正常去激活后结束，专用 Watch 已关闭，没有重启服务或改变主机输入。

这个独立结果证明产品账本、PCM 转换及提前创建的旧 engine **不是复现失败的必要条件**，且正常 guest 交互授权没有消除问题。它仍不能单独确定 CoreSimulator 音频桥接缺陷、宿主授权归属或其他平台 API 问题中的哪一种才是根因，也不能外推所有 watchOS Simulator 都不支持麦克风。
