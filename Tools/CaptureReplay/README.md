# 固定采样回放

`CaptureReplay` 保留 `verify-storage`，并提供按实际时间和加速回放两种采样节拍。对应 [P02](../../docs/plan/v0.1-execution-plan.md#p02时间分片与测试输入)、[S02、S06](../../docs/plan/device-validation.md) 及 [E2E 方案 8.1、8.2](../../docs/plan/e2e-test-plan.md)。新模式逐帧生成确定的低幅非语音信号，不复制短音频，不调用 ASR 或模型 API。

需要 macOS 15 或以上及项目当前完整 Xcode。工具使用生产 `PCM16SegmentWriter` / `AACSegmentWriter`、`RecordingStore`、`InboxCustodian` 和 `ArchiveStore`。这里的“手表”“手机”分别是同一 Mac 输出目录里的两个真实文件和 SQLite 存储实例。工具没有执行 Watch 麦克风、WatchConnectivity、iPhone 后台、独立音频回调生产者或真机长时采集。

## 构建与短时验证

从仓库根目录运行。依赖 pin 沿用本目录与根包的锁文件。共享 SwiftPM scratch 时须串行构建；以下命令不下载模型权重，不读取 API 凭证。

```sh
xcrun swift package --package-path Tools/CaptureReplay \
  --scratch-path Packages/MoMoAgentKit/.build resolve
xcrun swift build --package-path Tools/CaptureReplay \
  --scratch-path Packages/MoMoAgentKit/.build \
  --force-resolved-versions -c release -j 2 --product CaptureReplay
CAPTURE_REPLAY_BIN="$(xcrun swift build --package-path Tools/CaptureReplay --scratch-path Packages/MoMoAgentKit/.build -c release --show-bin-path)"
```

先跑 65.25 秒实时 AAC，再用相同输入跑 20 倍 AAC、PCM。每次都有一个完整 60 秒分片及一个短尾。输出必须是新目录，工具拒绝覆盖已有证据。

```sh
"$CAPTURE_REPLAY_BIN/CaptureReplay" replay --duration 65.25 --speed 1 --codec aac \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-realtime-aac
"$CAPTURE_REPLAY_BIN/CaptureReplay" replay --duration 65.25 --speed 20 --codec aac \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-fast-aac
"$CAPTURE_REPLAY_BIN/CaptureReplay" replay --duration 65.25 --speed 20 --codec pcm \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-fast-pcm
```

现有存储场景用原命令执行：

```sh
"$CAPTURE_REPLAY_BIN/CaptureReplay" verify-storage \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-storage
```

`verify-storage` 仍包含手写测试转录稿的入库验证，不代表 ASR 结果；新 `replay` 模式不写转录稿。

## 运行参数与时间口径

| 参数 | 含义 |
| --- | --- |
| `--duration` | 请求输入秒数，必须得到整数个 16 kHz 帧。例如 `65.25`、`64800`。 |
| `--speed` | `1` 为实时节拍，有限值 `>1` 为加速节拍。实际速度由报告计算。 |
| `--codec` | `aac`（默认）或 `pcm`；二者均为 16 kHz、单声道、60 秒分片。AAC 使用生产 32 kbps 配置。 |
| `--output` | 尚不存在的输出目录。中断或失败不会自动删除目录。 |

生成器每次只生成最多 512 帧。第 N 块的期限由累计帧数 `/ 16000 / speed` 得到，再通过 `ContinuousClock` 的绝对期限等待。帧编号从 0 连续增长；墙钟变化不会增加或减少输入帧。编码、收件或磁盘变慢时，工具保留全部原定帧并记录迟到，实际运行会超过请求节拍。

这个入口是串行、有回压的固定输入：当前片段完成持久接收后才继续送入下一块。它可检查长期等待、编码与持久链的共同运行，不能证明真实麦克风回调在慢收件时不会溢出。数据缓冲最多为 512 帧输入、生产分片器的一个片段，以及 8,192 帧解码缓冲。内存中的清单元数据随分片数增长，完整音频始终在磁盘上。

生成器为固定种子的 xorshift64，输出小幅 `Int16`；每个源帧都实际生成。`generatedPCMSHA256` 和 `appendedPCMSHA256` 对小端 `Int16` 源流逐块计算，可比较不同节拍是否送入相同数据。PCM 最终解码后再计算 `reopenedPCMSHA256`，必须和送入分片器的源流一致。AAC 为有损编码，只校验存储前后原文件哈希、解码帧数和范围，不宣称样本逐值相等或跨系统 AAC 字节必然相同。

## 持久链与报告

每个封口文件依次经过 Watch 账本、独立传输副本、手机收件箱、生产格式/解码/哈希校验、持久回执与 `ReceiptApplied`。Watch 只在有效回执落库后清理自身副本。编码目录的临时文件只在 Watch 已保存独立副本后删除。手机原音保留。

正常结束后，工具重开两端 SQLite，逐片申请手机原音 lease，重新核对哈希、解码帧数、连续范围、epoch 结束、确认账本与空队列。所有文件句柄都在同步读取函数结束时释放；不会跨数据库或网络 `await` 持有句柄。

| 文件 | 内容 |
| --- | --- |
| `plan.json` | 运行/设备/session/epoch ID、进程 ID、固定生成器、帧数、编码与节拍参数、系统版本。 |
| `report.json` | 状态、实际耗时、生成/送入/封口/收件/确认帧数、请求未覆盖范围、阶段耗时、节拍迟到、源流哈希与最终核验状态。启动及每片确认后刷新。 |
| `chunks.jsonl` | 每片封口、接收、确认、重开核验的帧范围、音频和清单 SHA-256、字节数、时间及阶段。每行写完同步落盘。 |
| `resources.jsonl` | 启动、每片确认和结束时的 RSS、进程峰值、可用磁盘、系统热状态及当前输入帧数。 |
| `watch/`、`phone/`、`encoding/` | 原始文件、SQLite、收件箱或未完成的编码现场。 |

`inputElapsedSeconds` 包含节拍等待、生成、编码及运行中的同步交付；`totalElapsedSeconds` 还包含收尾和最后核验。`achievedInputSpeed` 等于本次实际送入的唯一音频秒数除以 `inputElapsedSeconds`。每片事件的 `requestedBoundarySeconds` 是计划期限；事件实际耗时包含初始化开销，不能充当跨设备传输延迟。ASR 覆盖为未知，不填零完成率。

完整运行的正确性门槛是：请求帧全部送入、封口与收件；范围连续且无重叠；逐片哈希、解码和持久确认相符；重开后队列为空。出现断言或 I/O 错误返回 `1`，状态为 `failed`。短时运行只证明该时段；性能数值没有另设发布阈值，不自动外推 18 小时或真机结果。

## 停止与磁盘

工具启动时输出 PID。按 Ctrl-C 或发送 `SIGTERM` 后，它停止生成新块，封口已送入的短尾，完成这部分数据的收件与确认，再保存 `interrupted` 报告。SIGINT 返回 `130`，SIGTERM 返回 `143`。原计划时长仍保留，未覆盖范围不会从分母扣除；未完成的最终重开核验会明确标记。它不自动续跑已有目录。

`SIGKILL`、进程崩溃或断电无法执行收尾；最近一份报告可能仍是 `running`。已同步的清单、数据库及音频保留，活动 AAC 尾段保留生产草稿。进程强杀恢复由独立故障注入工具验收，不能把本工具的正常关闭当作强杀证据。

启动和每片提交前都读取真实文件系统余量。预检按剩余 PCM 原音的大小计算保守预算，再加四份临时分片、128 MiB SQLite/证据空间，并保留至少 2 GiB 空闲。它不是文件系统空间预留。18 小时 PCM 原音约 2.07 GB，AAC 按 32 kbps 约 259 MB，另有容器、数据库和证据开销。空间不足会停止并保留现场，不填满磁盘测试。

## 后续 18 小时运行

短时验证通过后，按 S06 分开执行两个新目录。实时命令会持续至少约 18 小时；不要在本轮短时验证中运行它。

```sh
"$CAPTURE_REPLAY_BIN/CaptureReplay" replay --duration 64800 --speed 50 --codec aac \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-18h-accelerated
"$CAPTURE_REPLAY_BIN/CaptureReplay" replay --duration 64800 --speed 1 --codec aac \
  --output /Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/capture-replay-18h-realtime
```

两项结果分别报告“18 小时等量加速输入”和“18 小时按实际时间 fixture”。均不能填写为 Watch 18 小时录音通过。正常场景运行期间不要主动休眠 Mac；若系统休眠或调度停顿，工具保留迟到和总耗时，不补造该时段的真实采集。

2026-10-14 已用完整 Xcode 的 Release 构建完成短时验证：65.25 秒实时 AAC、20 倍 AAC、20 倍 PCM 均收齐 1,044,000 帧，分片为 960,000 + 84,000 帧，三个源流 SHA-256 相同。PCM 重开解码后的 SHA-256 也相同。三项输入耗时分别为 65.253、3.263、3.263 秒；原有 `verify-storage` 的 11 项检查通过。

SIGTERM 初次运行暴露 Swift 6 actor 隔离错误：信号回调继承 MainActor，却在 utility queue 执行。工具给回调明确声明 `@Sendable` 后重建，重跑返回 143；已采样的 79,360 帧完成封口和持久确认，原计划中未采样的 964,640 帧保留为缺失。首次失败现场未删除。

本机证据位于 `/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/capture-continuous-01/`。其中 `verification.json` 记录独立重算生成器、读取实际音频/清单哈希、PCM 解码和两端 SQLite 回执后的结果。尚未执行 18 小时模式或真机采集。
