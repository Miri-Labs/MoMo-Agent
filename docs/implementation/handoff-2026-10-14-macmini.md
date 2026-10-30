# Mac mini：重启交接已完成（历史记录）

2026-10-14。用户已于 20:13 重启，BlackHole 2ch 已加载；本交接中的重启后步骤已经执行，不再作为待重启或待安装清单。当前入口请读[第一版使用检查点](v0.1-usable-checkpoint.md)和[实施记录](status.md)。手机新四色三项 UI、Watch `20261014-watch-blackhole-final-01` 正式三项均通过。最终参考布局 UI06 完整旅程另为 1/1，两项 native 沿用未改采集源码的原证据，不合称新一轮 3/3。Release10 已包含最终参考布局，手机与嵌入 Watch 构建成功，19/19 静态检查、17/17 检查器自检通过；118 个包内文件的 23 项额外 Debug/test 标识扫描零命中，367 项构建输入哈希前后不变。118 个文件的已授权密钥精确字节扫描零命中；手机和 Watch 均已安装启动，9 项可执行文件、Info.plist 与资源文件的 SHA-256 与快照一致。实际核验了手机浅/深色首页、原图标和 Watch 恢复中断录音后的正常结束确认；未新跑 Release 麦克风采样或全导航回归。本次实现与证据随当前分支提交保存；最终提交以本文件所在分支 Git HEAD 为准，远端同步由 `origin/codex/initial-implementation` 核对。不能宣称完整 v0.1 发布完成。

本次 Watch 边界实际采集 1,096,000 帧 / 68.5 秒（60 + 5.2 + 3.3 秒），包含默认 AAC 分片、标记、暂停/继续、文件 hash/解码和账本重开。完整 UI 已验证“静音”实际暂停、重启后继续、更多页结束确认和两个待确认原音重启保留；其后仅在宿主停止后清理隔离测试原音。采集通过采用 BlackHole 公开 fixture 受控输入，不证明物理 Watch、AirPods、后台、18 小时或真实 WC。

同源独立探针 A/B 的同步激活取得 144,000 帧，异步激活回调成功却为 0 Hz；正式音频会话现以专用串行后台队列执行同步 `setCategory` / `setActive(true/false)` 并异步等待，保留原错误、generation 与停止屏障。Watch 界面按用户参考采用状态/点阵/底部静音与标记，时长移入信息、停止移入更多；两端使用用户四色与原图标。最终 UI06 的显示层与 Release10 对应；此前 native 证据保持原轮次边界。

用户当前没有真机，仍只要求第一版基本可用。真实 OpenRouter 已运行，暂定事实分组等语义问题保留为已知限制，不再扩展质量矩阵。WC 文件传输按原计划和 Apple 限制留配对真机；模拟器测试不激活 WC、不伪造接收成功。以下保留重启前背景及当时的操作步骤，旧失败不删除。

## 当前工作副本与环境

- 权威 worktree：`/Users/syh/Workspace/MoMoAgent-worktrees/initial-implementation`，分支 `codex/initial-implementation`。不要在旧 `main` 主检出继续或覆盖它。
- Xcode 27.0 / 27A266a、Swift 6.4 与官方 iOS/watchOS 27 runtime 已安装。开发目录 `/Applications/Xcode.app/Contents/Developer`。
- iPhone：`AC2B247F-999E-48DA-BC31-A81CF5662EB0`；Watch SE3：`84B7054F-7749-4688-B703-896DA4FBA7D3`。本任务这两个设备尚未配对；其他默认配对未动。
- 固定模型与公开音频在被忽略的 `Models/`；主项目生成配置是 `project.yml`。
- 使用入口与手机逐轮结果见 [第一版检查点](v0.1-usable-checkpoint.md)，便携证据摘要见 [索引](evidence/2026-10-14-resume/evidence-index.json)。原始结果仍在本 worktree 的 `tmp_agent_output/`，不覆盖旧目录。

重启前已停止本任务手机/手表宿主并关闭上述两个模拟器，shutdown 均返回 0；未发现 MoMoAgent、CaptureProbe、xcodebuild、ffplay 或 LLDB 进程。正式 Watch App 容器当前没有音频文件，诊断 Recorder 的临时 WAV 也已清除。详见 `tmp_agent_output/20261014-virtual-audio-01/pre-restart-cleanup.json`。系统 CoreSimulator 辅助服务不代表 App 仍在运行。

## 重启前的 Watch 证据与修复（历史）

最初 guest 授权后仍为 0 Hz。独立 Recorder 探针随后触发了宿主 Mac 的麦克风请求；用户亲自允许后，host 日志确认 User Consent。正常权限已经处理，不再要求用户重复授权，不修改 TCC 数据库。

授权后的独立 Engine 曾恢复到 24 kHz / 1 声道，并在音频 tap 入口崩溃。LLDB 栈明确为 `RealtimeMessenger` → `_dispatch_assert_queue_fail` → `_swift_task_checkIsolatedSwift` → `CaptureProbe.run` 的 tap 闭包。SDK 将 tap 声明为 non-Sendable，同时允许后台线程调用；位于 MainActor 方法中的闭包继承了不适用的 actor 隔离。

探针和正式 `AudioCaptureEngine` 的 tap 已显式标注 `@Sendable`。生产闭包只捕获线程安全的 stream continuation，同步复制借用 buffer 后 yield，没有将 buffer 传给异步 Task，也没有关闭并发检查。该最小改动已独立审查、正式 Watch 测试构建成功。

探针修复后不再崩溃，但三秒内实际帧数仍为零；两端 Recorder 均 `prepare=true / record=false / 0 frames`。正式最短采集复测 `20261014-watch-sendable-e2e-01` 0/1，重新出现 0 Hz / `unsupportedInput`，未达到采集与暂停断言。所有失败保留，不能把启动成功或格式有效当作采样成功。详细过程见 [Watch 输入诊断](watch-simulator-input-diagnosis.md)。

## 重启前：BlackHole 已安装、当时尚未加载

用户提出 Mac mini 可用虚拟麦克风。已安装官方 BlackHole 2ch 0.7.1：下载包 SHA-256 为 `57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf`，签名为 Existential Audio Inc.（Q5C99V536K），Apple 公证与 Gatekeeper 检查通过，系统 receipt `audio.existential.BlackHole2ch` 已记录 0.7.1。

安装器返回成功，同时明确要求重启；安装后 `system_profiler SPAudioDataType` 尚未列出 BlackHole。官方新版安装流程要求整机重启，不能把旧源码开发指南的 CoreAudio-only 重启当作当前包免重启保证。本任务没有重启 Mac、杀死 coreaudiod 或更改 Mac 默认输入/输出。当前物理输入仅 AirPods；Mac mini 本身没有可用内置麦克风。

已生成公开中文样本的 90 秒、48 kHz、双声道 PCM 文件：

`tmp_agent_output/20261014-virtual-audio-01/zh-loop-90s.wav`

SHA-256：`31a4c94106ccfd8714bcfb060e05159083ad1e621fa8bb7716836a25f66559b4`。它由既有 `Models/TestFixtures/zh.wav` 循环生成，是受控测试输入，不是腕部环境录音。音频与安装包不入 Git。

## 当时的重启后操作步骤（现已执行）

以下用于复查与复现，不是当前必须再做的清单；不要重复安装、重启或覆盖旧证据。

1. 先核对 Git 状态和本文件，再读项目 `AGENTS.md`、Ponytail、SwiftUI Expert。检查 BlackHole 是否已出现，确认无旧测试/探针进程，使用全新结果目录。
2. 启动专用 Watch，Device Hub 的 Device → Sound → Sound Input 只给该设备选择 `BlackHole 2ch`，记下原选择，保持 Mac 默认声音路由不变。
3. 用现有 ffplay 定向播放固定文件。`SDL_AUDIO_DEVICE_NAME` 在本机 SDL2 中精确匹配设备，找不到就失败；不能回退到 Mac 默认扬声器。播放器由测试执行器持有 PID，设置有界时限，并在 finally 中停止。

   ```sh
   env SDL_AUDIODRIVER=coreaudio SDL_AUDIO_DEVICE_NAME='BlackHole 2ch' \
     /opt/homebrew/bin/ffplay -nodisp -autoexit -nostats -loglevel info \
     tmp_agent_output/20261014-virtual-audio-01/zh-loop-90s.wav
   ```

4. 先用独立 Engine 探针核对真实 callback 次数、非零帧数、RMS 和格式。探针不保存音频；Recorder 的临时 WAV 必须清理。没有有效帧时保留失败，不强造格式或绕过正式采集。
5. 探针通过后，使用已包含 `@Sendable` 的正式 Watch 测试构建，依次执行最短采集/暂停恢复、实际跨默认 60 秒 AAC 分片及完整 UI 旅程。复用 `tmp_agent_output/20261014-watch-input-diagnostics-01/DerivedData` 的有效构建缓存，但不复用或覆盖结果目录。先核对源码哈希，源码若变化则重建。
6. 验收文件 hash/解码帧、标记、暂停/恢复、重启后的待确认原音，以及截图中的实际状态；停止播放器、宿主并清理本轮独立测试录音。将结果明确标为 **虚拟设备受控输入**，不声称 SE2 真机、WatchConnectivity、后台或续航已通过。
7. 若需要产品修补，再执行对应回归并生成匹配最终源码的 Release；不要拿此前 Release06 的结果覆盖后来 tap 修改。最新包信息见检查点。

本次不需要再调用付费 API 来验证音频输入。OpenRouter 凭据仍只从用户授权的本机 OpenClaw 配置读取；不打印、不复制入仓库或命令行。用户尚未要求再扩展 Agent 内容质量。
