# Watch Apple API 最小采集复现

独立 watch-only App，bundle ID `com.momoagent.diagnostics.captureprobe`。只依赖 Apple SwiftUI、AVFoundation、Foundation、OSLog，不链接 MoMo Agent 的录音账本、PCM 转换、同步、Speech 或 Agent。每进程选择一次 `Engine 3 秒` 或 `Recorder 3 秒`，两个 API 路径独立，避免先创建 engine 影响 Recorder 对照。

Engine 单次手动启动依次申请麦克风权限、设置 `.record/.default`、调用 `setActive(true)`，然后创建一个全新 `AVAudioEngine`，只获取一次 `inputNode`。CLI 的 `--engine-probe --async-activation` 改用 `activate(options:completion:)` 并等待回调，其余步骤相同；报告记录 `activationAPI`。非零格式时采集三秒，仅计帧和 RMS；0 Hz/0 channel 直接记录真实失败，不安装无效 tap，不改格式或生成声音。

Engine 不写原音文件。`Documents/capture-probe.json` 和统一日志只保存权限、格式、route、帧数/RMS、耗时、错误和清理结果。该工具不证明后台、SE2、WatchConnectivity 或长时采集。RMS 为零也可能是安静输入，不能自动判定为权限问题。

Recorder 路径根据本机 watchOS 27 SDK 的 `AVAudioRecorder.h`（watchOS 4+）实现：同样先授权和激活 session，使用 session 的实际采样率和 mono 16-bit PCM/WAV，调用 `prepareToRecord` 与 `record(forDuration: 3)`，最多等待六秒 delegate 完成。统计由关闭后的真实文件以 4096 帧块解码得出，不使用返回成功值或墙钟代替音频帧。只有完成回调成功且实际时长约三秒时记为 `captured_three_seconds`；其他真实部分输入仍如实记录失败。

Recorder 只在 App 临时目录短暂写 `recorder-probe-<UUID>.wav`，正常、失败和取消路径均停止、关闭、读取统计后删除原音。`Documents/recorder-probe.json` 逐阶段更新，仅有统计和临时文件名。如果进程崩溃或被强杀，执行者须在停止 App 后按本轮 JSON 的确切文件名检查并清理对应 App `tmp` 中的 WAV，再保存 `temporaryAudioRemoved` 的外部核对；不可把临时 WAV 导出到证据目录。没有上传或网络请求。

从本目录用 XcodeGen 生成独立工程，再用独立 DerivedData 和 `-jobs 1` 构建；可增量复用此工具的既有 DerivedData。不要改主工程或产品路径。安装到既有专用 Watch Simulator 后从 Device Hub 手动打开 App、选择本轮 API，或通过 `simctl launch <UDID> com.momoagent.diagnostics.captureprobe --recorder-probe` / `--engine-probe` 显式选择一次路径。无参数时保持手动选择。处理实际系统权限提示。通过 `simctl get_app_container <UDID> com.momoagent.diagnostics.captureprobe data` 找到只含统计的报告，并保存同时间段 guest/host 音频日志。完成后停止 App、检查临时原音已清除、关闭该专用设备。

`PhoneCaptureProbe` scheme 使用完全相同的 Sources，但独立 iOS bundle `com.momoagent.diagnostics.phonecaptureprobe`，用于排查 Watch 与共用宿主通路的差异；不得把 iPhone 对照当作 Watch 通过。应用临时文件与清理要求相同。

显式异步激活选项在 iOS 需要 27+；旧 iOS 明确报告 `asyncActivationUnavailable`，默认同步路径不变，不提高工具原来的 iOS 18 部署要求。`20261014-capture-probe-async-availability-build-01` 已将最终 guard 版本的 Watch/iPhone 两 target 顺序编译通过，源码哈希稳定；该轮仅编译，不新增音频运行结论。

不修改 TCC 数据库、主机全局输入、系统信任或 CoreSimulator 服务。输入格式为零时保留结果，不无限重试。

2026-10-14 实测：Xcode 27、watchOS 27、既有 SE3 44 mm 专用设备，构建/安装成功，guest 首次麦克风弹窗允许后仍是 hardware 0 channel / 0 Hz、output 2 channels / 0 Hz，0 帧，`zeroInputFormat`，session 已正常去激活。未进入三秒采样。证据 `tmp_agent_output/20261014-watch-minimal-probe-01/`；诊断、宿主权限归属及边界见 [说明](../../docs/implementation/watch-simulator-input-diagnosis.md)。首次互斥 watch-only plist 配置的安装失败另保留；修正只涉及本诊断工程。

Recorder 扩展已于 `tmp_agent_output/20261014-watch-recorder-probe-02/` 构建成功，前后源码哈希一致。首轮仅诊断工具的 tuple 标签编译错误保留在 `…-01`。后续 Recorder 触发宿主真实权限提示；用户允许后 Watch 与同源 iPhone 对照都返回 record=false、实际零帧。每轮原音已清除，见 `…watch-recorder-probe-03/04`、`…phone-recorder-probe-01`。

授权后 Engine 进一步暴露 Swift 6 tap 回调继承 MainActor 的真实 SIGTRAP。`…watch-engine-stack-02/lldb.log` 保留 `swift_task_checkIsolatedSwift` 的完整栈。探针改为显式 `@Sendable`、只捕获锁保护的统计对象后，`…watch-engine-sendable-01` 已验证启动成功、24 kHz/1 channel，但三秒仍零帧，正常停止。`tapCallbacks` / `emptyTapCallbacks` 计数先在 `tmp_agent_output/20261014-capture-probe-counters-build-01` 完成两个 target 的顺序增量编译，源码哈希稳定；该轮仅编译，前述结果不可当作正数音频采集通过。重启后的实际计数见下节。所有历史失败继续保留，完整边界见[诊断说明](../../docs/implementation/watch-simulator-input-diagnosis.md)。

## 受控虚拟输入

BlackHole 2ch 0.7.1 官方签名包安装后，本机已于 20:13:32 重启，并实际枚举出 48 kHz 双向设备。仅在 Device Hub 为 Watch `84B7054F-7749-4688-B703-896DA4FBA7D3` 选择 Sound Input → BlackHole 2ch，不修改全局默认输入或输出。每轮用独立、有限时长的播放器进程定向公开 fixture，例如从仓库根运行：

```sh
env SDL_AUDIODRIVER=coreaudio SDL_AUDIO_DEVICE_NAME='BlackHole 2ch' /opt/homebrew/bin/ffplay \
  -nodisp -autoexit -loglevel info \
  tmp_agent_output/20261014-virtual-audio-01/zh-loop-90s.wav
```

该文件为 90 秒、48 kHz、双声道、16-bit PCM，SHA-256 `31a4c94106ccfd8714bcfb060e05159083ad1e621fa8bb7716836a25f66559b4`。保留播放器日志并核对实际输出路由；环境变量只是路由请求，设备缺失或回落默认设备时不能继续声称配置成功。不使用无限播放；每个测试阶段启动新的有界播放，结束时停止本轮 PID。

先运行三秒 Engine，检查实际帧数大于零、已知非静音输入的 RMS、callback/空 buffer 数及实际格式。然后才按[正式测试说明](../../Tests/WatchIntegrationTests/README.md)顺序跑最短暂停恢复、65 秒 AAC 边界与 UI 三个用例，保存全新证据和清理结果。必须注明这是公开 fixture 经虚拟音频设备送入原生采集链路的**受控虚拟输入**；不等于腕部、物理麦克风或真实佩戴验证。

重启后 `20261014-watch-blackhole-probe-01` 同步激活取得 144,000 帧、48 kHz/2 channel、30 callbacks/0 empty、RMS 0.10462。正式短用例随后仍在异步激活后的输入格式检查失败，未到达暂停恢复断言；失败保留在 `20261014-watch-blackhole-e2e-01/short`。

同一冻结探针二进制、同一 Watch/BlackHole 路由、新进程顺序 A/B：`20261014-watch-activation-sync-01` 得 144,000 帧、30 callbacks/0 empty、RMS 0.070857；`20261014-watch-activation-async-01` 的 async completion 返回 active 成功，但新 engine 为 0 Hz/0 channel、0 帧。两轮输入哈希相同，所有播放器、日志和探针进程结束，未保存原音。两个 API 均被本机 SDK 支持；这只是当前 runtime/路由的实测差异，不证明所有 watchOS 异步激活均有问题。

随后正式 Watch 会话改为在同一后台串行队列执行受支持的同步激活/去激活，保留错误和等待顺序。`20261014-watch-blackhole-final-01` 已在同一冻结产物上完成三项正式验收：实际采样/暂停恢复、默认 60 秒 AAC 边界、用户新参考布局的完整 UI 旅程，全部通过。正式结果与范围见 [测试 README](../../Tests/WatchIntegrationTests/README.md)，不能只凭此独立探针替代产品验收。

最后显示层调整后，`20261014-watch-blackhole-e2e-06` 以正式 App 完成 13 秒真实预览、正常暂停/结束及原音清理，再执行完整 UI 旅程 1/1 通过。它通过未变音频源哈希关联 `final-01` 的两项原生采样结果，没有重复 65 秒用例，也不合称为新 3/3；详见上述测试 README。
