# iPhone 蓝牙耳机录音 · 实施记录 · 2026-10-29

方案见 [iPhone 蓝牙耳机录音方案](../plan/iphone-earphone-capture-20261028.md)，路由实验见[耳机切换实验](earphone-route-spike-20261027.md)。功能面向所有提供 HFP 麦克风的蓝牙耳机（含 AirPods），目前只在 Shokz OpenMove 上真机测试，后续在 AirPods 等耳机上补测。功能先在迁移前仓库实现并试用，2026-10-29 移植到本仓库 `0.0.1` 首发树（模块名 `WML*` → `MoMo*`）。2026-10-30 首发树被重写为 `d879285e` 后再次移植：录音模块和资料库的接口未变，只在 `PhoneRuntime`、根视图和设置页合并了少量冲突（保留新增的传输延迟激活、说话人更新回调和续跑批次核对），README 同步改为“蓝牙耳机录音（测试版）”。

## 实现

| 部分 | 位置 |
| --- | --- |
| 路由与输入门（deactivateFirst，等待 HFP 链路最多 2 秒） | `Apps/iPhoneApp/Platform/EarphoneAudioRoute.swift` |
| 采集运行时（切换、epoch、保活、打断、退避重试） | `Apps/iPhoneApp/Application/EarphoneCapture/EarphoneCaptureRuntime.swift` |
| 本机交付到资料库（分段、采集事件、删除） | `Apps/iPhoneApp/Application/EarphoneCapture/EarphoneLocalDelivery.swift` |
| 录音设备偏好 | `Apps/iPhoneApp/Application/EarphoneCapture/CaptureDeviceSettings.swift` |
| 切换诊断日志 | `Apps/iPhoneApp/Application/EarphoneCapture/EarphoneCaptureLog.swift` |
| 状态卡片、MoMo 小标、设置页 | `EarphoneStatusView.swift`、`PhoneRemoteView.swift`、`CaptureDeviceSettingsView.swift` |
| 与回放、语音输入交接音频会话 | `AudioPlaybackController.swift`、`ChatVoiceInput.swift`、`ClientControls.swift` |

共享模块只改两处：`SourceKind` 新增 `phone`，`AudioCaptureEngine` 新增 `isRunning`。iPhone target 依赖 `MoMoRecording`，`UIBackgroundModes` 增加 `audio`，麦克风说明补充耳机录音。

诊断日志位于 `Application Support/MoMoAgent/EarphoneCapture/events.jsonl`，超过 512 KB 轮换一次。只记录端口类型、耗时和错误码，不含音频、文字或设备名称。

## 修复记录

首次真机试用时，音乐暂停后切回耳机，界面一直显示“耳机未连接”。原因是会话激活后立即查找 HFP 输入，此时耳机的通话链路尚未建立；随后每 3 秒按同样方式重试。改为最多等待 2 秒，直到输入出现并成为当前路由；连续失败的重试间隔从 3 秒倍增到 60 秒。

## 录音时开始播放：开头约 1 秒通话音质

试用中，录音时其他 App 开始播放，用户听到的过程是：开头约 1 秒声音发闷，像打电话的音质；接着约 1 秒空白；之后恢复正常高音质。诊断日志把这个过程分成以下几段：

| 阶段 | 实测 | 用户听到 |
| --- | --- | --- |
| 音乐开始到 App 发现 | 每次都在一个轮询周期（0.25 秒）内，没有主线程延迟 | 通话音质 |
| 发现到 iOS 切回 A2DP | 0.69–0.85 秒，中位数 0.74 秒 | 通话音质 |
| 耳机从 HFP 切到 A2DP | App 测不到，由耳机决定 | 约 1 秒空白 |

原因在原理上：录音时耳机处于 HFP，其他 App 的声音只能先从已建立的 HFP 链路播出；iOS 切换会话要约 0.7 秒；耳机切换蓝牙模式还要再断开一下。只要录音会话保持可混音并在后台持续运行，这一段就无法去掉。迁移前的构建也是同样的原理和耗时（中位数 825 ms），这不是迁移造成的退化。

为缩短这一段做了两处改动：

- **路由切换与封口并行**：原来先停止输入、等编码器封口并记录最后一段，再切换路由；现在停止输入后立即切换路由，封口同时进行，下一次切换开始前仍等待封口完成。实测切回 A2DP 的中位数从 825 ms 降到约 740 ms，耳朵基本听不出差别。
- **诊断日志新增两项**：`otherAudio.started` / `otherAudio.stopped` 记录发现外部音频的时间和触发方式；`poll.late` 记录轮询晚于 0.5 秒的情况。

改用可被其他 App 打断的会话，理论上能去掉开头的通话音质。但录音会被挤掉，App 在后台可能被挂起，音乐停止后不一定能自动恢复；导航播报等短提示音也会打断录音。因此未采用，如需要另开实验分支验证。

## 验证

- 测试：新增 `EarphoneLocalDeliveryTests` 3 项，覆盖三件事：分段与 epoch 结束进入资料库且两侧收据落地；删除正在录音的会话须等待停止；手表会话的删除不由本机处理。模拟器集成测试 45 项通过，包括 `EarphoneLocalDeliveryTests`、`PhoneReceiveStatusTests`、`BackgroundGrantLifecycleTests`、`ChatVoiceInputTests`。
- 构建：本仓库树在 iPhone 17 Pro Max（iOS 26.7.1）上以个人团队签名构建安装，新代码无编译警告。用户在该构建上复测录音、放歌、暂停后恢复录音，结果正常。

### 真机试用（迁移前构建，2026-10-28 至 10-29）

设备为 iPhone 17 Pro Max 加 Shokz OpenMove，音乐 App 为网易云音乐。数据来自设备上的诊断日志、录音账本和资料库。

| 项目 | 结果 |
| --- | --- |
| 切换 | 116 次，全部成功，无“耳机未连接”误判 |
| 切到耳机录音耗时 | 中位数 367 ms，最长 2297 ms |
| 切回高音质耗时 | 中位数 825 ms，最长 1159 ms |
| 保存的耳机录音 | 约 127 分钟，168 段，全部进入资料库；167 段已转写，1 段排队 |
| 打断 | 2 次（2–8 秒），结束后自动恢复 |

外部音频停止后，大约 1.5 秒才开始保存：检测最多 0.25 秒，静音确认 1 秒，切换到首个采样中位数 0.34 秒。用户确认可以接受，静音确认时长不调整。外部音频开始后，0.25 秒内停止保存。

## 已知限制

- 录音时其他 App 开始播放，开头约 1 秒是发闷的通话音质，随后约 1 秒空白，之后恢复正常，原因见上文。
- 进入 HFP 后，耳机按键是通话控制，不能恢复播放，需在屏幕、Siri 或以后的语音指令中恢复。
- 只在 OpenMove 上测试过。只支持 8 kHz 窄带通话的耳机音质更差；只有 LE Audio 的设备不支持；多点连接的耳机需要实测。
- 没做锁屏 30 分钟以上的专门挂机测试，不过试用中有连续数小时的后台录音会话。
- 新版说话人区分也会处理耳机录音。如果声纹来自手表录音，耳机音频的自动匹配可能偏少，尚未评估。
