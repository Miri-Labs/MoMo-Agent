# Speech 执行诊断

`SpeechQuality --diagnostics` 使用生产 SpeechEngine 测量处理成本，报告独立于中文质量评测。它不读取 90 分钟 corpus，不计算 CER，也不向既有 `utterances.jsonl` 写入内容。

在协调好的构建时段编译同一个 SpeechQuality executable，运行：

```text
SpeechQuality --diagnostics MODEL_DIRECTORY OFFICIAL_ZH_WAV NEW_OUTPUT_DIRECTORY SOURCE_VERSION
```

- `OFFICIAL_ZH_WAV` 是 SHA-256 为 `b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373` 的官方样本。
- 输出目录必须不存在，放到本轮 `tmp_agent_output/` 子目录中。
- `SOURCE_VERSION` 使用 `uv run Tools/SpeechQuality/source-version.py` 输出的当前源码摘要。

工具截取该样本的 `[8000, 78000)` 帧，循环生成 60 秒和 180 秒压力输入，按 60 秒拆成真实 WAV 文件。这是合成高语音负载，不是自然会话或质量真值。每组运行完整准备、从头重复准备和逐窗口真实 ASR；报告比较窗口身份，并记录重复读取量。单独选择完整 20 秒核心，在 native 开始事件后 10 ms 调度取消。只有时间记录确认取消发生在实际 C 调用区间内，才报告取消残留时间；没有重叠就保留报告并失败。取消后再用同一执行者完成一次识别。

## 字段口径

每个 `prepare` 或 `transcribe` 调用生成一份 `SpeechDiagnostics`，包含独立 operation ID、attempt ID 和配置指纹。回调不包含路径、正文或音频，计数器只归当前调用所有。调用方需要保存时自行接收 `onDiagnostics`；默认回调不保存数据。

| 字段 | 含义 |
| --- | --- |
| `elapsedSeconds` / `queueWaitSeconds` | 从提交到返回前的总耗时 / 串行执行者排队耗时。两者相减是该操作的执行时间。 |
| `modelHashSeconds` / `modelHashedBytes` | 首次加载的模型文件校验成本；热调用为零。 |
| `modelLoadSeconds` / `vadLoadSeconds` | ASR 运行库初始化 / 本轮 VAD 初始化成本，不包含前述模型哈希时间。 |
| `audioHashSeconds` / `audioHashedBytes` | 当前调用校验的音频文件成本；每次实际重读均计入。 |
| `audioReadSeconds` | 读取与重采样耗时，扣除内嵌的音频哈希时间。 |
| `sourceFramesRead` | 从原文件实际读取的帧，使用源采样率；包含转换器预读。 |
| `convertedModelFrames` | 转换器实际返回的 16 kHz 帧；包含后来丢弃的前缀和预读尾部。 |
| `discardedPrefixModelFrames` / `discardedSuffixModelFrames` | ASR 为还原同一转换状态而读取、但未传给本窗口的前缀 / 尾部帧。 |
| `vadModelFrames` | 送入 VAD 的 512 帧累计数量，包含闭合短尾补零。 |
| `coreModelFrames` | 本次 ASR 窗口的有效核心帧，用于与重复解码分开核算。 |
| `nativeDecodeSeconds` | 仅同步 C decode 调用的时间；排除事件回调与前处理。 |
| `cancellationToNativeReturnSeconds` | 首次取消到 C decode 返回的时间，仅取消发生在 C 调用期间时存在。 |
| `cancellationToOperationEndSeconds` | 首次取消到本次操作收尾的时间，包含等候正在运行的计算。 |

时间项存在包含关系，不能把全部字段直接相加。外部回调必须迅速返回，不能在 Speech 串行执行者中写大文件或等待其他任务。诊断工具先收集小型记录，再在调用结束后写 JSON。

`speech-60s/diagnostics.json` 与 `speech-180s/diagnostics.json` 分别保留原始逐调用记录。唯一核心帧按窗口范围去重；重放计数保留每次实际读取，不能增加 RTF 的有效输入分母。`native-cancellation.json` 保留取消运行；`native-cancellation-and-reuse.json` 额外包含取消后的正常识别。模型冷启动和压力输入生成不混作 native decode 时间。

本工具不测量真机热状态、能耗、RSS 上限或系统后台到期行为。Mac 的耗时结果不能用作 iPhone 的后台期限。

## J27 有界长输入测量

`stress.py` 扩展上述独立诊断，不改变生产 `MoMoSpeech`。一次只运行一种时长和语音占空比，先测 1,800 秒，再根据实际增长决定 7,200 秒的期限。`--speech-duty 1` 为持续重复短语，`--speech-duty 0.3` 为每 30 秒插入 9 秒短语、21 秒零值静音的间歇压力型。这个比例是**插入 fixture 的比例**，不是人工标注或 VAD 实际判断的语音比例；间歇型也不能代表已经采集的日常生活分布。

```sh
# 使用自己的独立 scratch；同一目录可增量构建，不能与其他构建器并发写入。
swift build --package-path Tools/SpeechQuality --configuration release --jobs 1 \
  --scratch-path /absolute/owned/scratch --force-resolved-versions

uv run Tools/SpeechQuality/source-version.py
# 将上一条输出逐字传入 SOURCE_VERSION；输出目录必须不存在。
uv run Tools/SpeechQuality/stress.py \
  --binary /absolute/owned/scratch/out/Products/Release/SpeechQuality \
  --model Models/Speech --fixture Models/TestFixtures/zh.wav \
  --output tmp_agent_output/NEW_UNIQUE_STRESS_RUN --source-version SOURCE_VERSION \
  --seconds 1800 --speech-duty 1 --deadline-seconds 900
```

时长限制为 60～7,200 秒、60 秒的整数倍；内部期限限制为 10～3,600 秒。Swift `--diagnostics` 的原有四参数 60/180 秒模式保持不变。长输入的 `--prepare-only` 和 `--run-prepared` 是 runner 管理的两个阶段，不应跳过中间独立输入检查。

- 准备阶段只保留原样本裁出的 70,000 帧和一个 60 秒 WAV 的缓冲。每片约 1.92 MB，30 分钟约 57.6 MB、两小时约 230.4 MB。没有一次载入整段 PCM、下载新模型或增加无限队列。
- Python 在推理启动前独立检查固定模型与原样本 SHA、全部 WAV 的实际时长/采样率/声道、分片帧连续性、内容哈希及每个 PCM 样本是否符合指定占空比。原工具的 Float32 乘法与四舍五入量化保持原样；不能用 Float64 的不同舍入结果冒充同一输入。
- 生产 `SpeechEngine.prepare` 按原 checkpoint 分析，随后逐窗口调用正式 `transcribe`。工具不改窗口、分析锚点、VAD 或转换器状态。生产批次自身的窗口数组仍保留，其最大数量另行报告；工具不累计整段转写文本或诊断数组。
- 每次诊断回调只放入单项槽，返回后立刻写 `operations.jsonl`；覆盖未消费项会失败。`progress.jsonl` 保存真实窗口、分析/无语音覆盖、已完成位置和积压。全部输入在开始时可用，因此积压是**离线存量排空**，不是实际实时收件或后台队列。
- `rss.jsonl` 每 500 ms 读取当前进程 RSS，并在结束时补一次采样。报告的是采样最大值和趋势，不能称为捕获所有瞬时峰值、无泄漏证明或 iPhone 内存门槛。时间计量从创建引擎后的首次分析前开始，包含首次哈希/模型加载；生成和独立输入校验在该计时之前。
- 工作负载完成后，用同一个引擎和实际窗口执行 10 ms native 取消探针，再正常识别一次。只有实际诊断确认取消落在 C decode 区间内才通过；这些额外调用独立标相，不计入主要吞吐分母。
- 内部期限取消当前 `SpeechAttempt`。外部 runner 在期限后额外给 30 秒退出窗口，再依次 TERM/KILL 并等待，每步最多 10 秒；取消或失败保留 JSONL 与失败报告，不填造余下窗口。收到 runner 的 SIGTERM/SIGINT 也会清理其子进程组。

`inspection.json` 由独立 Python 检查器重建实际窗口、native 诊断、无语音/分析覆盖、积压末点和取消后复用的一致性；只有 `completion.status` 并不足以通过。检查器不写 Archive/录音账本，也不将工具结果登记为产品已转写。负向自检见 `Tests/Quality/test_stress_evidence.py`。

此测量仍是 **Mac Release、同一公开短音频重复、离线存量处理**。不能计入 90 分钟 CER 数据集，不能证明 30 分钟/两小时真实时钟采集、WatchConnectivity、iPhone 热状态、能耗、背景调度或三日实际佩戴。若连续型前缀读取或耗时增长过大，先保留失败和逐窗口增长数据，再单独讨论生产优化，不改压力比例或放宽期限来覆盖结果。

### 2026-10-14 本机测量

证据根为 `tmp_agent_output/resume-20261014-syh/`，汇总 `j27-measurement-summary.json`；四组均已通过真实模型执行、逐文件独立输入检查、窗口/分析覆盖/诊断计数检查，以及同一引擎的实际 native 取消与恢复。各目录保留 `execution-report.json`、`workload/{run.json,input-verification.json,operations.jsonl,progress.jsonl,rss.jsonl,completion.json}`。30 分钟两组额外的 `inspection-v2.json` 采用增强后的准备调用计数检查，原报告继续保留。

| 输入压力型 | 输入时长 | 实际窗口 | 包含首次加载的处理耗时 | 丢弃前缀 / 有效核心帧 | 采样 RSS 最大值 |
| --- | --- | --- | --- | --- | --- |
| 持续重复人声 | 30 分钟 | 90 | 49.00 秒 | 44.52 倍 | 870.1 MiB |
| 30% 插入短语、70% 零值静音 | 30 分钟 | 60 | 17.02 秒 | 0.114 倍 | 870.7 MiB |
| 持续重复人声 | 2 小时 | 360 | 334.29 秒 | 179.52 倍 | 818.5 MiB |
| 30% 插入短语、70% 零值静音 | 2 小时 | 240 | 60.96 秒 | 0.119 倍 | 875.3 MiB |

对应目录依次为 `j27-1800s-continuous-01`、`j27-1800s-intermittent-01`、`j27-7200s-continuous-01`、`j27-7200s-intermittent-01`。所有输入在启动时即已存在，最后的离线积压为零。四组取消至 native 返回分别为 0.370、0.204、0.488、0.146 秒；这是这些实际短窗口的观察，不是任意输入的取消上限。

持续型输入增加 4 倍，累计丢弃前缀从 1,281,973,088 帧增为 20,679,904,928 帧，增长 **16.13 倍**，验证当前重复读取随长人声区间显著增长。两小时转写阶段累计校验读取 42.05 GB 文件字节，哈希约 40.21 秒、读取/转换约 76.27 秒、native 约 190.78 秒；文件缓存可能参与这些逻辑读取，不能称为物理磁盘流量。此次没有修改生产分析锚点或转换规则。

本机不是独占基准环境：30 分钟两组与其他任务/构建重叠；两小时连续型开始时没有 Xcode/Swift 编译进程，间歇型开始时有根任务的 Xcode 测试驱动，均可能与模拟器 UI/API 活动并行。连续型中途观测到约 3524 MiB 交换区使用及 RSS 明显变化，记录见 `j27-system-vmstat-midrun.log`、`j27-long-series-01.json` 和汇总。因此 **6.82 倍耗时增长不能全部归因于前缀算法，RSS 下降也不能证明没有泄漏或总内存占用下降**。

检查器自检 10/10，包含删除准备/native 诊断、遗漏/重复覆盖、取消未重叠、清单变化和实际外层超时进程回收。首轮短测 `j27-smoke-continuous-01` 在独立 PCM 检查处失败，尚未启动推理：Python Float64 与原 Swift Float32 在六个样本舍入点不同。修正检查器的明确量化规则后，两型 60 秒短测及上述四组均通过；原失败目录未覆盖。

## 顺序读取优化与恢复边界

上述旧基线的每个 ASR 窗口从同一个分析锚点重建转换器，因此长时间没有静音锚点时，后面的窗口反复读取前面音频。随后针对这一实测缺陷实现显式顺序读取；原单窗口接口和原始基线仍保留。

正式顺序路径保持同一个转换器连续推进，保留至多一个窗口及读前缓冲；每个窗口仍独立领取、提交并检查持久屏障。Archive 持有显式输入快照 lease，取消后待 C 返回、读取器关闭才释放。新文件、当前未读完文件及与 context 相交的已打开文件都完整 SHA 校验；没有 stat 缓存代替 hash。停止/修订/删除/失败都终止序列，恢复仍从原持久锚点开始，没有直接 seek 到核心区间。详细不变量、负向反例和初轮未归因 AAC 微差见[顺序读取说明](../../docs/implementation/speech-sequential-reading.md)。

60/180 秒模式现在在同一真实输入上分别运行旧单窗口和顺序路径，保存旧诊断为 `fresh-reader-observations.json`、精确识别比较为 `sequential-equivalence.json`，主 `diagnostics.json` 的转写计数来自顺序路径。长压力按每个真实分析批次显式创建/关闭读取序列；没有跨取消或进程重启的隐式缓存。

### 顺序读取后的固定源码复测

最终版本为 `sha256:864db9c174a3b4ed8f4b345e720177ec54c359573c5eb2ac0de82d08acd7bd0c`，Release binary SHA 为 `2a8428bf97e3e24ae6dec660566674f67acb9e98bb83e3fa7e04b31b99bee83a`。`j27-optimized-build-02.json` 与各运行报告保存构建/运行前后源码摘要；最终运行没有同时编辑测量源码。

| 持续输入 | 旧转写转换帧 | 新转写转换帧 | 旧丢弃前缀帧 | 新丢弃前缀帧 | 旧 / 新转写哈希逻辑字节 | 旧 / 新总处理秒数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 30 分钟，90 窗口 | 1,310,970,880 | 28,800,000 | 1,281,973,088 | 0 | 2.734 / 0.228 GB | 49.00 / 41.73 |
| 2 小时，360 窗口 | 20,795,895,808 | 115,200,000 | 20,679,904,928 | 0 | 42.047 / 0.920 GB | 334.29 / 282.17 |

输入从 30 分钟增加至两小时，新转写实际转换帧严格增加 4 倍，恰好各读一遍该批次输入。新哈希逻辑读取仍包含当前文件及 padding 的重复完整安全校验，因此大于原始 WAV 大小，但不再重复整个已消费前缀。

最终新目录为 `j27-optimized-1800-continuous-02` 和 `j27-optimized-7200-continuous-02`；汇总 `j27-optimized-comparison.json` 还保存证据 SHA。独立比较器在运行后重新读取新旧 150 个 WAV，全部与原独立校验哈希一致；450 个窗口的 source/model core/context、anchor、配置和实际识别文本 SHA 全部相同。不同运行的 session/chunk UUID 不同，跨运行 window ID 不声称相同；同一输入的 window ID、文本、tokens、timestamps 精确对照见 `j27-optimized-small-02` 的 60/180 秒结果（3/9 窗口，丢弃前缀均 0）。

两组最终压力均通过真实 native 取消与同引擎恢复，取消至 native 返回分别为 0.366、0.483 秒。RSS 采样峰值分别为 986.6、842.4 MiB；这些结果不能证明内存下降。30 分钟启动时 root 正在构建 App；两小时启动时无编译，但后段与 root 模拟器验证重叠，在约 296～308 窗口间出现明显停顿，主机观测到约 3.65 GB swap。两小时 native 总耗时 252.46 秒（旧基线 190.78 秒），末四分位每窗 1.59 秒，明显受共享主机条件影响。因此只将**读取帧与逻辑字节的增长**作为本次算法结论，不把总耗时变化当独占性能基准，更不替代 iPhone 设备预算。
