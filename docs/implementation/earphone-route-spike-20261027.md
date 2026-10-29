# 耳机 / iPhone 麦克风自动切换实验 · 2026-10-27

用于决定 iPhone 本地录音输入策略的真机实验。实验 App（`Tools/AudioRouteSpike/`）与原始日志只保留在迁移前仓库 `xilanhua12138/MoMo-Agent` 的 `blankchenxm/exp/audio-route-spike` 分支和本机 `tmp_agent_output/`，不随本仓库提交；结论已用于 [iPhone 蓝牙耳机录音](iphone-earphone-capture-20261029.md)。

## 背景与要验证的问题

用户没有 Apple Watch，计划以 iPhone 配合 Shokz OpenMove（S661）持续录音，并全天用这副耳机听音乐。调研结论：

- iPhone 上的第三方蓝牙耳机只有 A2DP（高音质播放、无麦克风）与 HFP（双向、电话音质）两种模式；iOS 不对第三方耳机提供 LE Audio。使用耳机麦克风就会让音乐降为电话音质。
- OpenMove 为蓝牙 5.1，零售参数只列 SBC；未查到宽带 HFP（mSBC，16 kHz）支持，可能只有 8 kHz 窄带。续航约 6 小时。
- Apple 开发者论坛中 DTS 的说明：App 一般不能在后台从零开始录音。

已确认的方案：有其他 App 播放声音时，蓝牙保持 A2DP，录音会话保留但改用 iPhone 内置麦克风，**音频不保存**，仅为了保持“随时能切回”；无声音播放时切到 HFP，用耳机麦克风录音并保存。用户单击耳机多功能键暂停 / 继续播放即可触发切换。

本实验要回答：

1. 后台时能否可靠检测其他 App 开始 / 停止播放（`isOtherAudioPlaying`、`secondaryAudioShouldBeSilencedHint` 与对应通知）。
2. 每次切换从决定到收到新输入的耗时与录音断档。
3. 切到 A2DP 后音乐是否恢复高音质；HFP 期间开始播放时的电话音质持续多久。
4. 两种切换方式的差别：重设 category（A2DP-only / HFP），或同时允许两者、只改 preferred input。
5. OpenMove 在 HFP 下的实际输入采样率（8 kHz 或 16 kHz）。
6. 后台完全停止后能否重新开始录音（验证设计前提）。
7. 来电、Siri 打断后的恢复，以及耳机断开时的行为。

## 实现

`Tools/AudioRouteSpike/`：独立 SwiftUI App，iOS 26，Swift 6，不依赖 MoMo Agent 模块。

- 会话：`.playAndRecord` + `.mixWithOthers` + `.defaultToSpeaker`。music 模式加 `.allowBluetoothA2DP` 并优先内置麦克风；headset 模式加 `.allowBluetoothHFP` 并优先 HFP 输入。`preferredInput` 策略同时允许两者，只切换优先输入。
- 检测：每 0.25 秒轮询，并监听 `silenceSecondaryAudioHintNotification`。有播放立即切 music；静音持续 `quietDelay`（默认 1 秒，可调）后切 headset，避免切歌间隙来回切换。
- 采集：每次启动新建 `AVAudioEngine` 以获取新路由的硬件格式；tap 以显式 `@Sendable` 闭包运行（避开项目此前遇到的 MainActor 隔离断言）。headset 段写入 CAF，music 段只计时长不保存（可在调试开关中保存）。
- 记录：`events.jsonl` 记下检测变化、切换开始、首个新缓冲到达（切换耗时）、超过 150 ms 的断档、路由与采样率、打断、场景前后台以及错误码。
- 后台重启测试：点击后 10 秒内锁屏，App 在后台完全停止录音并停用会话，3 秒后尝试重新开始，记录成功或错误码。

构建：Xcode 27.1 / iOS 26 SDK，`generic/platform=iOS` 不签名 Debug 构建通过，无 Swift 并发警告；产物 Info.plist 含 `UIBackgroundModes = audio`。工程为手写的同步文件夹格式：下载固定版本 XcodeGen 的操作被本机自动权限拒绝，未绕过。

## 真机测试步骤

设备：iPhone 17 Pro Max，iOS 26.7.1；耳机只连 iPhone。每项测试新开一次「开始」，结束后导出 `session-*` 目录到 `tmp_agent_output/audio-route-spike/`。

| 编号 | 操作 | 观察 |
| --- | --- | --- |
| T1 | 不放音乐，开始 | 进入 headset；`route` 输入为 BluetoothHFP；记录采样率 |
| T2 | 前台打开音乐 App 播放 | 检测延迟；切到 music；耳朵判断音质是否恢复 |
| T3 | 锁屏，用耳机单击暂停 / 继续，重复 5 次 | 后台检测与切换是否每次成功；切换耗时、断档；开始播放时电话音质持续多久 |
| T4 | 用视频 App 重复 T3 | 视频播放是否同样被检测 |
| T5 | 切换方式改为 preferredInput，重复 T2、T3 | 输出能否保持 A2DP；切换耗时是否更短 |
| T6 | headset 模式下关闭耳机，再打开 | 是否回到内置麦克风；耳机回来后是否恢复 |
| T7 | 录音中来电（或唤起 Siri） | 打断与恢复是否成功 |
| T8 | 后台重启测试 | 后台从零开始录音是否被拒，记录错误码 |
| T9（可选） | 锁屏挂机 30 分钟，期间放歌和暂停若干次 | 长时间后台是否稳定 |

## 结果

### 第 1 轮（T1–T3，category 策略）

日志：`tmp_agent_output/audio-route-spike/device-20261027-a/session-2026-10-27T22-10-52Z/`（events.jsonl，7 段耳机录音）。iPhone 17 Pro Max（iOS 26.7.1），OpenMove 只连手机，音乐 App 为网易云音乐。

- **OpenMove HFP 输入为 16 kHz 单声道**（宽带），硬件格式由 `AVAudioEngine` 输入节点读取。iPhone 内置麦克风为 48 kHz。耳机麦克风满足 ASR 的 16 kHz 输入要求。
- **后台检测可用**：锁屏时 `isOtherAudioPlaying` 与 `secondaryAudioShouldBeSilencedHint` 同步变化，0.25 秒轮询能及时发现播放开始 / 停止。
- **切到耳机（music → headset）稳定**：从决定到首个 16 kHz 缓冲 555–603 ms，前后台均成功。
- **切回听歌（headset → music）在后台失败**：`setActive(true)` 返回 `'!int'`（`AVAudioSession.ErrorCode.cannotInterruptOthers`）。同一切换在 App 处于 inactive / active 时成功，但耗时 1.8 秒，其中 `setCategory` 从 HFP 改为 A2DP 约 1.6 秒；此期间音乐仍走 HFP。偶有成功的后台切换（339–372 ms）发生在会话已被系统停用之后。另有一次 category 已切换但引擎启动返回 `'what'`（2003329396）。
- **实现缺陷放大了失败**：切换前先停止引擎，失败后无输入，App 被系统挂起，直到用户回到前台；每 0.25 秒重试一次，持续十余秒。用户观察到网易云提示“被其他应用打断”、稍后又恢复，与这段反复激活时间吻合（未取得网易云侧日志，因果未证实）。

### 第 2 轮（preferredInput 与 category 对照）

日志：`tmp_agent_output/audio-route-spike/device-20261027-b/session-2026-10-28T00-1*/`、`…T00-20-13Z/`。用户反馈：两种方式继续播放后音乐都不是正常音质；有时按耳机键无法恢复播放。

- **preferredInput 不可行**：会话同时允许 A2DP 与 HFP 时，即使优先输入设为内置麦克风，输出始终是 `BluetoothHFP`，从未回到 `BluetoothA2DPOutput`。切换本身在后台成功（约 0.7 秒），但音乐一直是电话音质。
- **category 在后台仍被拒**：本轮按步骤记录，失败点是 `setCategory`（`'!int'`），连续 7 次（3 秒退避）均失败；保留的耳机输入未中断，App 未被挂起。回到前台后同一切换成功，耗时 1.8 秒。
- **耳机按键无法恢复播放**：日志不能直接证明。推测是 HFP 音频链路建立后耳机处于“通话中”状态，多功能键单击按说明书映射为“挂断”，没有发出 AVRCP 播放指令。
- “后台重启测试”本轮点击后未锁屏（`appState=active`），**后台从零开始录音的限制仍未验证**。

结论：在 iOS 上，用 OpenMove 做“暂停自动切到耳机麦克风、播放切回高音质”时，后台切回 A2DP 的这一步被系统拒绝。新增 `deactivateFirst` 策略作最后尝试：停止引擎并停用会话，再设置 category 并重新激活；该策略失败时会失去输入。

### 第 3 轮（deactivateFirst）

日志：`tmp_agent_output/audio-route-spike/device-20261027-c/session-2026-10-28T00-25-39Z/`。用户反馈：音质恢复正常；锁屏后按耳机键可以暂停，但无法再次播放，只能在屏幕上点。

- **后台双向切换可行**：锁屏状态下 headset → music 与 music → headset 共完成 6 个来回，全部成功。从决定到首个新缓冲 767–825 ms，切到 music 后输出为 `BluetoothA2DPOutput`。
- **后台重新开始录音成功**：后台重启测试中，后台停用会话后，轮询自愈在 0.3 秒内重新激活会话、启动引擎；测试自身 3 秒后的重启也成功（均为 `appState=background`）。本次 App 仍在后台任务保活期内，长时间挂起后能否在后台开始录音未验证。DTS 论坛说法与本次结果不一致，以真机结果为准，继续观察。
- **按键无法恢复播放**：符合第 2 轮的推测。暂停 1 秒后进入 HFP，此后单击不再产生播放。日志中后台的 music 切换都由屏幕上的播放触发。

第 4 轮构建：默认策略改为 `deactivateFirst`。注册 `MPRemoteCommandCenter` 的播放 / 暂停 / 切歌命令并记录，验证 HFP 期间的按键是否会交给本 App；若收到，立即切回 A2DP 并保持 15 秒，让下一次按键作为正常播放命令发给音乐 App。暂停后切换延迟可选 1 / 3 / 5 / 10 / 20 秒。

### 第 4 轮（按键截获与切换延迟）

日志：`tmp_agent_output/audio-route-spike/device-20261027-d/session-2026-10-28T00-3*`（3 次）。用户反馈：进入耳机录音后按键能听到提示音，但音乐无法开始。

- **HFP 期间的按键没有交给 App**：3 次会话共 0 条 `remote.command`。按键被耳机按“通话中”处理（有提示音），iOS 没有转成播放命令；本 App 也收不到。按键截获方案不可行。
- **切换延迟内按键正常**：延迟 10 秒的会话里，锁屏状态下 10 秒内暂停 / 继续两次，均停留在 A2DP，按键正常恢复播放。
- 在屏幕上恢复播放时，切回 A2DP 的流程照常（约 0.7 秒）。

结论：只要进入 HFP，OpenMove 的按键就无法恢复音乐，只能在切换延迟内按键，或在屏幕 / Siri 上恢复。下一步需用户在“延长延迟”“对话结束后自动退出 HFP”等方案中取舍。

用户决定（2026-10-28）：不延长切换延迟（1 秒即可）；“有其他 App 播放声音”涵盖音乐、视频等所有外部音频，此时不保存；进入 HFP 后恢复播放靠屏幕 / Siri / 今后的语音指令，接受按键无法恢复播放。

### 第 5 轮（三种策略复测与耳机关机，2026-10-28）

日志：`tmp_agent_output/audio-route-spike/device-20261028-e/session-2026-10-28T14-*`（4 次）。构建同第 4 轮。

- **三种策略对照**（同一天、同一耳机）：
  - category：headset → music 1757–1783 ms，成功，但切换时 `appState=inactive`（控制中心 / 锁屏遮挡，App 未进入后台）；结合第 2 轮，真正后台时仍会被拒。
  - preferredInput：开始即为 `out[BluetoothHFP]`，音乐始终电话音质。
  - deactivateFirst：双向共 9 次切换全部成功，music 方向 729–1000 ms，headset 方向 818–844 ms，输出回到 `BluetoothA2DPOutput`。
  - 结论：1b 采用 deactivateFirst。
- **T6 耳机关机再开机通过**：关机时路由变为 `oldDeviceUnavailable` → 内置麦克风 / 扬声器，引擎配置变化后 0.3 秒内以 48 kHz 继续采集；开机后 `newDeviceAvailable`，轮询自愈 0.4 秒内回到 16 kHz HFP；之后播放仍正常切回 A2DP。全程无超过 150 ms 的断档。关机期间内置麦克风音频仍按 headset 段保存（12.6 s，48 kHz）；1b 需决定此时保存并标注来源，还是不保存。
- **后台重启测试**：按钮被连续点击十余次，测试互相叠加；锁屏后的每次停止 / 重新开始均成功（`appState=background`）。
- 按键无法恢复播放与策略无关：任何使用耳机麦克风的方式都必须进入 HFP，此时 OpenMove 按键按通话控制处理。

用户决定（2026-10-28）：**暂时只保存耳机麦克风的音频，任何情况下都不保存 iPhone 麦克风的音频**（耳机关机、断开、有外部音频播放等）。1b 规则：

- 只有当前输入为 `BluetoothHFP` 时写入录音；输入是内置麦克风（或其他非耳机输入）时，采集照常运行但丢弃样本，与听歌模式相同。
- 不在耳机离开时停止采集：没有进行中的录音，App 在后台会被挂起，既检测不到耳机回来，也可能无法在后台重新开始录音（长时间挂起后的情况尚未验证）。内置麦克风只用于保持录音会话，不保存。
- 判断依据是实际输入端口，而不是 App 内部的模式名，以免路由被系统改掉时误存（第 5 轮关机期间的 12.6 s 即属此类）。
- 以后若需要“无耳机时用手机录音”，作为可选开关另行讨论，并为每段标注输入来源。

修正（第 2 轮构建）：先配置会话、成功后才重启引擎，失败时保留原输入；只在选项变化时 `setCategory`，会话只激活一次；失败退避 3 秒；每步错误标注调用名称；轮询发现引擎意外停止时自动恢复。

## 待办

已完成：T1–T6、T8。1b 输入策略已定：deactivateFirst，切换延迟 1 秒，只保存耳机麦克风音频。

推迟到 1b 的正式构建上验证（用户 2026-10-28 决定先进入 1b，以后再测）：

- T7 来电：录音中来电，挂断后是否自动恢复耳机录音。
- Siri：HFP 期间长按耳机键 2 秒能否唤起 Siri。
- T9 长时间挂机：锁屏 30 分钟以上，期间放歌、暂停若干次，确认未被挂起。
- 长时间挂起后能否在后台重新开始录音。
- “只保存耳机麦克风”规则：耳机关机期间不产生保存的录音。
