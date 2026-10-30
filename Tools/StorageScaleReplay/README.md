# 18 小时等量存储链路验收

`StorageScaleReplay` 在 Mac 上逐帧生成确定的低幅非语音信号，经过生产 `AACSegmentWriter` 编码、`RecordingStore` 封口和 SQLite 记账，再由 `ArchiveStore` 校验、解码、收件和确认。每个文件包含实际 60 秒音频，16 kHz、单声道、AAC 32 kbps。工具不复制短语音扩充样本，不提交虚构转录稿。

对应 [E2E 方案 8.1、8.2、11.3](../../docs/plan/e2e-test-plan.md)。本工具验证加速软件数据量和恢复正确性。实时 18 小时、Watch 麦克风、WCSession、手机后台、VAD/ASR、模型 API 和三天手机使用预算仍需独立验收。

## 运行

需要 macOS 15 及以上和项目当前完整 Xcode。依赖版本沿用根包与本目录的 `Package.resolved`。构建不读取模型权重或 API 密钥。与其他 SwiftPM 构建共享 scratch 时须串行运行。

从仓库根目录运行。首次解析会为新工具刷新锁文件的 `originHash`；确认三项依赖 pin 与根包一致，再构建 Release。`SCALE_BIN` 仅保存本任务的产物目录。

```sh
swift package --package-path Tools/StorageScaleReplay \
  --scratch-path Packages/MoMoAgentKit/.build resolve
swift build --package-path Tools/StorageScaleReplay \
  --scratch-path Packages/MoMoAgentKit/.build \
  --force-resolved-versions -c release -j 2 --product StorageScaleReplay
SCALE_BIN="$(swift build --package-path Tools/StorageScaleReplay --scratch-path Packages/MoMoAgentKit/.build -c release --show-bin-path)"
```

先做每批 6 分钟的 smoke。输出路径必须尚不存在，临时运行产物放在工作区 `tmp_agent_output/` 下。

```sh
"$SCALE_BIN/StorageScaleReplay" --output /absolute/path/to/tmp_agent_output/storage-scale-smoke --hours 0.1
```

正式等量运行省略 `--hours`，默认值为 18。

```sh
"$SCALE_BIN/StorageScaleReplay" --output /absolute/path/to/tmp_agent_output/storage-scale-full
```

`--hours` 必须得到 3～1,080 个整分钟分片。只有每批为 18 小时的结果才标注正式数据量，其余均为 `profile=smoke`。工具不会把 smoke 改名为 18 小时通过。

## 冻结的规模与传输条件

| 场景 | 输入 | session 数 | 分片数 | 每批确认后待传 |
| --- | --- | --- | --- | --- |
| 单批 | 18 小时 | 54 | 1,080 | 6 小时，随后排空 |
| 三批 | 每批 18 小时，共 54 小时 | 162 | 3,240 | 6、12、18 小时，随后排空 |

每个 session 最多 20 分钟，独立 epoch；时间锚点按三批相隔 24 小时生成。手机侧每批只确认 12 小时等量文件，最后停止新增并排空。这个固定额度用于制造可预测积压，不代表手机每天获得了 12 小时执行机会，也不衡量 ASR 吞吐。

全部运行共编码 72 小时合成输入，约 41 亿帧。实际 CPU 耗时由报告记录，不能以合成时间跨度代替运行时间。编码使用有界 8,192 帧输入缓冲，每份音频分别生成；最终检查音频 SHA-256 唯一性和每段帧范围。

## 检查内容

- 每个阶段启动独立子进程，重开真实数据库。一个阶段保留“已收件但尚未回执”的分片，以及一个已落收件箱但未提交的文件，随后退出；下一进程恢复两条路径。这里使用正常进程退出，不冒充操作系统强杀或 watchdog。
- 使用生产文件提交状态，最多保留 4 个待完成传输名额，检查第 5 个名额被拒绝。每组倒序收件，并周期性重复投递；这验证软件预算，没有执行 WCSession。
- 每个 Receipt 校验音频和清单哈希。重复应用回执须返回原有应用消息；无回执的 Watch 原音不得清理。控制消息按持久 rowid 游标读取，每页不超过 32 条和 16 KiB，并在新进程从头重放。
- 收件结束后保存真实分页游标并退出。另一进程从该游标继续读取全部 session，检查无遗漏和重复。正式数据量超过页面大小；小规模 smoke 可能只产生一页。
- 最后逐片重新申请原音 lease，触发生产哈希校验；核对独立输入账本、连续帧范围、epoch 结束和唯一 mark。已接收覆盖必须等于计划输入，最终待传队列和收件箱必须为空。
- ASR 配置传 `nil`：处理时长与 Watch 采集状态须为未知，不能把合成输入说成转写完成或实机采集。

## 报告与门槛

`report.json` 保存每阶段的进程 ID、真实耗时、生成/确认/待传秒数、重复投递、实际复制字节、文件与数据库体积、RSS 采样及进程峰值。编码阶段每个 session 采样一次；不同进程的内存曲线分别比较，不能以重启后的低 RSS 证明长期无泄漏。

`receiveCommitLatency` 是同步复制、收件验证与提交的毫秒分布，含样本数、P50、P95、最大值。阶段内保存原始值。重启检查点的收件耗时没有纳入这个分布，数量单列为 `receiveCommitUnmeasuredCount`。它不是 Watch 到手机的传输延迟。ASR RTF、跨设备延迟和手机处理预算均未执行，不填零值或通过结论。

本次可判断的正确性门槛为零违例：丢失原音、错误确认、逻辑重复、帧范围不守恒、游标遗漏，以及排空后仍有待传项。内存、热状态和延迟的发布数值在方案中尚未冻结；工具保存观测值，不据此宣布性能门槛通过。任何断言或磁盘检查失败均返回非零，保留数据和已完成阶段，最终状态为 `failed`。

## 磁盘与清理

正式 72 小时 AAC 原音按 32 kbps 估算约 1.04 GB，另有 SQLite、清单和短暂副本。启动检查采用双份音频上界加 128 MiB 元数据预算，再保留至少 2 GiB 空闲空间。每阶段和编码过程中也会检查容量。空间不足时工具停止，保留已有证据，不删除其他文件。

输出包含 `work/1-batch/` 与 `work/3-batch/` 的原音、数据库和阶段记录。顶层保存报告、完成阶段、冻结计划及逐片输入哈希。确认报告后可只清理成功运行的工作数据：

```sh
"$SCALE_BIN/StorageScaleReplay" --cleanup-work /absolute/path/to/tmp_agent_output/storage-scale-full
```

清理命令核对运行 ID 和成功报告，再删除 `work/`。顶层报告、计划与输入账本保留。失败运行拒绝自动清理，先检查对应错误和原始文件。

## 2026-10-14 实测

Release 构建和每批 6 分钟 smoke 通过。正式运行 `storage-scale-full-01` 也通过，实际执行 413.056 秒：

| 指标 | 单批 18 小时 | 三批各 18 小时 |
| --- | ---: | ---: |
| 独立 session / 分片 | 54 / 1,080 | 162 / 3,240 |
| 每批确认后的积压 | 6 小时 | 6、12、18 小时 |
| 最终积压 | 0 | 0 |
| 最终输入账本、哈希、回执与游标核对 | 通过 | 通过 |

合计执行 116 次重复收件；四个 SQLite 数据库的独立 integrity_check 为 ok，外键错误为零。4,312 个同步收件提交样本的 P50 为 16.455 ms、P95 为 22.755 ms，最大 53.128 ms；另 8 次重启检查点收件没有计时。最高进程峰值 RSS 为 95.28 MiB。各阶段有独立进程，且这次运行与部分 UI 测试及 Release 编译重叠，不能据此声明持续运行内存稳定或手机性能达标。

本机证据目录为 `mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/storage-scale-full-01/`。其中 `report.json` 保留全部阶段与测量，两个 `*-inputs.jsonl` 保留独立输入账本，`database-audit.json` 和 `verified-databases/` 保留独立审计及四个数据库快照。确认成功后清理 `work/` 中约 1.11 GiB 合成原音和中间文件；报告、快照及输入哈希保留。重新核对音频需按固定生成规则再次运行。
