# 中文转写质量基线

本工具先测 60 分钟公开普通话朗读的 CER。音频来自 Google FLEURS，推理复用生产 `MoMoSpeech.SpeechEngine` 的 Silero VAD、窗口规划、SenseVoiceSmall 和模型校验。每条原始音频作为独立、闭合的 epoch，按生产 checkpoint 继续分析直到文件结束，再按窗口顺序保留识别结果。

这是一项 Mac 上的语音质量测量。Watch 录音、连续跨文件语音、WatchConnectivity、手机后台调度和腕部声学条件另行验证。当前资料没有人工语音区间，因此报告里的 VAD 漏检率固定为 `null`，状态为 `pending`。

## 资料与许可

| 项目 | 固定值 |
| --- | --- |
| 数据集 | [Google FLEURS](https://huggingface.co/datasets/google/fleurs)，`cmn_hans_cn / test` |
| revision | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` |
| 许可 | CC BY 4.0；保留 Google FLEURS 与 Conneau et al. 的署名及来源 |
| 元数据 | `data/cmn_hans_cn/test.tsv`；原始文本、规范化文本、文件名、采样数、性别 |
| 原始归档 | `data/cmn_hans_cn/audio/test.tar.gz`，525,346,466 bytes |
| 归档 SHA-256 | `09d19ad18f5d7e91076880807e866cd16abd924c7052b55f71cdae91714fc166` |
| 选取规则 | `momoagent-fleurs-zh-v1`；句子 ID 去重、固定哈希顺序、男女各 30 分钟 |

选择器先按句子 ID 归组，再向累计时长较少的性别组分配一条录音。组内通过固定文件名哈希选择录音。随后按整数采样数选择完整句子，使每组恰好达到 28,800,000 帧。相同句子文本不能重复出现。此过程不读取模型输出，不裁剪句子，也不复制音频凑时长。

2026-10-14 准备得到 337 个不同句子、57,600,000 帧，即 60 分钟文件时长，包含自然停顿：

| 分布 | 数量 |
| --- | ---: |
| 女性 / 男性 | 202 / 135 条；各 30 分钟 |
| 小于 8 秒 / 8 至不足 15 秒 / 至少 15 秒 | 97 / 190 / 50 条 |
| 参考文本含拉丁字母 / 含数字 | 60 / 71 条，可重叠 |

这是按性别时长均衡的样本；句长按固定顺序选取并报告分布。FLEURS 不提供可用于本工具的说话人 ID，不能据性别数量推断不同说话人数。官方说明明确其重点是朗读语音，日常对话和噪声场景需要另建分层。

## 准备命令

在仓库根目录执行，所有原始音频和生成清单进入已忽略的 `Models/Quality`。Python 使用标准库，不安装数据处理框架。可先用 hf-cli 查看固定文件的下载计划：

```sh
HF_HUB_DISABLE_IMPLICIT_TOKEN=1 hf download google/fleurs \
  data/cmn_hans_cn/test.tsv data/cmn_hans_cn/audio/test.tar.gz \
  --type dataset --revision 70bb2e84b976b7e960aa89f1c648e09c59f894dd --dry-run

uv run --no-project Tools/SpeechQuality/corpus.py Models/Quality/fleurs-zh-v1 --plan-only
uv run --no-project Tools/SpeechQuality/corpus.py Models/Quality/fleurs-zh-v1
```

准备脚本通过匿名 HTTPS 流式读取归档，只保存白名单内的 WAV。它会读完整个压缩流以核对归档 SHA-256，但不会保存压缩包，也不会完整解压。每个文件核对 RIFF 格式、帧数和独立 SHA-256。只有归档与全部选中文件验证完成后才生成 `manifest.json`。

脚本拒绝超出 700 MiB 的目标目录，并保留至少 1 GiB 可用磁盘。当前选中 WAV 共 230,419,546 bytes；包括元数据和清单的目录实占约 222 MiB。它保留原始 float32 WAV，由生产音频读取器处理，不另存整套 PCM16 副本。

准备失败时不会发布可运行的 manifest。重复执行会验证已有资料。归档中断会从头读取压缩流，但不会增加另一份完整归档。已存在且内容不同的音频或清单会明确报错，需另建版本目录。

固定清单的校验值：

| 文件 | SHA-256 |
| --- | --- |
| `selection.json` | `3d311a21ec9efc9c766b223eac95af637f28fa915b57a2bbbc9396c8feac8993` |
| `manifest.json` | `ceb79bc670238bf2402887d3245ce864103608388495e3225b3f44d6ccc2b676` |

清单包含每条文件名、句子 ID、两种参考文本、帧数、性别、原始音频哈希、字节数及归档成员路径。来源、许可、参考标注状态、选择规则和元数据哈希一并保存。

## 构建、运行与评分

构建和重 ASR 由测试协调者串行安排。复用现有模型目录；此工具不下载模型，不调用云端 API。以下使用主包已有 scratch 目录，避免重复下载 native 依赖：

```sh
swift build --package-path Tools/SpeechQuality \
  --scratch-path Packages/MoMoAgentKit/.build -c release --product SpeechQuality

momo_quality_run="$PWD/tmp_agent_output/20261014-speech-quality/run-01"
momo_quality_source="$(uv run --no-project Tools/SpeechQuality/source-version.py)"

swift run --package-path Tools/SpeechQuality \
  --scratch-path Packages/MoMoAgentKit/.build -c release --skip-build SpeechQuality \
  "$PWD/Models/Speech" "$PWD/Models/Quality/fleurs-zh-v1" \
  "$momo_quality_run" "$momo_quality_source"

uv run --no-project Tools/SpeechQuality/score.py \
  Models/Quality/fleurs-zh-v1 "$momo_quality_run"
```

结果目录必须尚不存在。`source-version.py` 对当前工具、MoMoSpeech、MoMoContracts、Package 配置和已有依赖锁文件计算哈希，包含尚未提交的修改。Swift 入口从真实文件核对哈希、格式和解码帧数；同一个 SpeechEngine 串行完成全部样本。它不直接调用另一套 native ASR 接口。

输出包括：

- `run.json`：资料清单哈希、源代码标识、模型哈希、生产配置及指纹、平台和范围。
- `utterances.jsonl`：每条完成或失败状态、原始识别文本、窗口及帧范围、native JSON、tokens、时间戳、分析覆盖和耗时。逐条落盘，音频或输出句柄不跨 native `await` 保持打开。
- `completion.json`：完整执行后的成功数、失败数、总耗时。进程中断时此文件不存在。
- `cer.json`：总体及性别、句长分组 CER，S/D/I 计数，完成数与缺失数。完整无错误运行才提供 RTF。
- `comparisons.json`：逐条原始参考、规范化参考、原始输出、实际计分输出与编辑距离，供人工复核。

一个样本失败不会隐藏其他样本结果；CLI 完成剩余样本后以失败状态退出。评分器把失败或缺失样本作为空识别结果计入完整分母，同时把报告标为 `incomplete`。重复 ID、未知 ID、音频身份不符、参考文本偏离固定 TSV 或完成数量矛盾会直接报错。

## CER 口径

主指标使用 FLEURS 的规范化参考文本。参考和输出都进行 Unicode NFKC、casefold、去空白及 Unicode 标点处理，版本为 `nfkc-casefold-remove-punctuation-whitespace-v1`。数字与汉字数字不互换，繁简不互换，英文重音不删除，符号不统一删除。因此“9”和“九”等 ITN 差异仍会计错。

按 Unicode 字符计算 Levenshtein 编辑距离，主 CER 为全部 `S + D + I` 除以全部参考字符数，不平均各句百分比。等价路径按替换、删除、插入的固定顺序取值。另外报告逐句 CER 平均值与未经规范化的原始文本 CER，便于检查评分规则的影响。CER 可超过 100%。

有多个 ASR 窗口时，按窗口顺序连接文本，不用参考答案修正或去重。padding 造成的重复词同样计错。对原始文本的对照保留在窗口结果中。

报告表示测量完成状态，不自动宣告达到质量阈值。实体准确率及 VAD 漏检率保持待标注；不能把当前 Silero 的输出、整条文件长度或强制对齐结果直接当作人工语音真值。

## 其余 30 分钟候选

```sh
uv run --no-project Tools/SpeechQuality/candidates.py Models/Quality/candidates-v1

# 需要实际素材时再执行。约 115 MiB，不运行 ASR。
uv run --no-project Tools/SpeechQuality/candidates.py Models/Quality/candidates-v1 \
  --fetch-environment-and-music
```

| 分层 | 来源和准备行为 | 待完成项 |
| --- | --- | --- |
| 20 分钟环境声 | 作者 [ESC-50 仓库](https://github.com/karolpiczak/ESC-50)，固定 `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6`。仅取 ESC-10 的 rain、sea_waves、crackling_fire、clock_tick、helicopter、chainsaw，共 240 条。逐文件保存来源署名。 | 类别标签不保证没有背景人声；必须核听后确定负例和语音区间。 |
| 5 分钟音乐 | [Kevin MacLeod 官方目录](https://static.incompetech.com/music/royalty-free/music.html)：Cipher 的 0–180 秒与 Sneaky Snitch 的 0–120 秒；CC BY 4.0。准备入口下载原曲，记录裁剪意图。 | 首次下载才固定音频哈希；来源 URL 无不可变版本。核听和实际裁剪尚未完成。 |
| 5 分钟受控重叠 | 从同 revision FLEURS dev 固定选出男女各 300 秒、句子不重复的来源名单。保留独立参考文本和 dev 归档哈希。 | 当前只准备来源名单，没有下载、混音或生成语音区间。需记录每路增益、偏移及人工区间。 |

ESC-10 数据集许可为 CC BY 3.0；上述六类的逐源许可标签为 CC0 或 CC-BY。完整 ESC-50 为 BY-NC，本入口没有选用其余类别。许可与逐文件署名保存在下载目录的元数据中。[作者许可](https://github.com/karolpiczak/ESC-50/blob/33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6/LICENSE)

`candidates.json` 与可选的 `downloaded.json` 均保留 `humanListening=pending`、`humanSpeechIntervals=pending`。下载完成不改变人工审核状态，也不进入当前 60 分钟 CER 分母。2026-10-14 只生成了候选名单，未下载这些候选音频。

电视对白、带歌词音乐、自然多人插话，以及腕部的低声、远场、衣袖摩擦、运动和风噪仍待补充。公开素材可以在拿到 Watch 前验证软件推理；腕部质量需要以后用真实设备录音建立独立测试集。

## 本地验证

```sh
uv run --no-project python -m unittest discover -s Tests/Quality -p 'test_*.py' -v
```

这些小测试覆盖固定选取、时长与句子去重、归档白名单、目录穿越和链接拒绝、帧数/哈希损坏、低磁盘，以及 CER 的编辑计数、归一化、错误样本分母和错误来源拒绝。它们不替代真实模型运行。

2026-10-14 已完成固定来源下载、全归档哈希校验、337 条 WAV 帧数与单文件哈希检查。12 个 Python 单测全部通过；Swift Release 构建通过；真实生产 VAD + ASR 完成 337/337 条，无运行错误、无缺失样本。

## 2026-10-14 实测基线

本次在 Apple M4、16 GiB 内存、macOS 27.0（26A428）的 Mac 上执行。模型文件已在本机准备好；一个 `SpeechEngine` 串行处理各个文件，每个文件作为独立闭合 epoch。采用生产默认配置：`language=auto`、ITN 开启、2 个线程、VAD 阈值 0.5、最短语音 0.25 秒、最短静音 0.5 秒、padding 0.3 秒、单窗口 core 上限 20 秒。没有为测试样本调整配置。

| 指标 | 结果 |
| --- | ---: |
| 完成 / 错误 / 缺失 | 337 / 0 / 0 条 |
| 原始文件总时长（含停顿） | 3,600 秒 |
| 主 CER | **8.9683%**（1,157 / 12,901 字符） |
| 替换 / 删除 / 插入 | 476 / 589 / 92 |
| 未规范化的原始文本 CER | 14.8718%（2,157 / 14,504 字符） |
| 逐句 CER 平均值 | 7.7736% |
| 运行耗时 | 60.544 秒 |
| RTF（运行耗时 / 原始文件时长） | 0.016818 |
| ASR 窗口 | 441 个；80 条音频含多个窗口 |

计时覆盖逐文件校验、真实 VAD、ASR 与结果落盘，不含下载和编译。计时从首次 `prepare` 前开始，native 模型按需初始化，因此没有单独剔除首次模型初始化。这是本机已有模型文件的单次运行，不能视为独立的冷启动或预热延迟测试。

| 分组 | 条数 | 主 CER |
| --- | ---: | ---: |
| 女性 | 202 | 8.8561% |
| 男性 | 135 | 9.1432% |
| 小于 8 秒 | 97 | 6.7930% |
| 8 至不足 15 秒 | 190 | 8.9142% |
| 至少 15 秒 | 50 | 11.0755% |

上述分组用于保留本次分布，不据此推断性别、句长与错误之间的因果关系。

### 评分与最差样本复核

独立审计脚本没有导入生产评分器。它用完整 Levenshtein 矩阵及回溯重新计算全部 337 条原始与规范化文本的 S/D/I，逐条结果、总分母和 CER 与报告完全一致。337 条音频哈希、字节数、官方 TSV 中的文件名、句子 ID、参考文本、采样数及性别均匹配。原始参考和官方规范化参考经过本工具规则处理后，337 条结果一致。

441 个窗口的 ID、来源哈希、帧范围、anchor 换算和时间顺序均一致。每条总输出恰好等于各窗口原始文本按顺序连接，原生 JSON 的文本与 tokens 也一致。本次窗口的 padding context 没有重叠。每条文件的分析覆盖完整，VAD core 与 no-speech 范围恰好覆盖全文件；这项检查只证明区间记账闭合，不证明语音检出正确。

最差样本存在需要核听的集中现象：48/337 条官方参考含括号内的拉丁文本，按 CER 排序最差的 20 条全部属于这 48 条。部分输出保留了中文名称，却没有括号内的英文译名。下表保留原始评分，不删除括号内容，也不重新计算“修正后”成绩。

| 音频 ID | 本次 CER | 文本对照中可见的问题 |
| --- | ---: | --- |
| `14374188311472206884` | 50.0000% | 中文、拉丁姓名及混合语种词组产生多处差异；输出来自 5 个窗口。 |
| `10604423531103587528` | 43.6782% | 中文句子规范化后对应完整；参考中机构名的括号英文未出现在输出中。 |
| `149040922025982373` | 40.0000% | 中文人名及句子对应完整；参考中的括号拉丁人名未出现在输出中。 |
| `5088084912998887179` | 23.8095% | 参考中的“福克兰”在输出中变为“兰克”或“弗兰克”；该参考没有括号拉丁文本。 |
| `1453904934495738372` | 22.2222% | `2.4Ghz`、`5.0Ghz` 与输出的“2点G赫兹”“5G赫兹”不一致。数字与单位表达仍按既定规则计分。 |

本轮完成文本与文件身份审计，尚未逐条核听这些音频。因此，括号内容的差异可能涉及实际朗读、参考文本或识别结果，当前不能归因为参考标注错误，也不能全部认定为 ASR 漏识别。后续应先核听上述最差样本并留存独立人工记录，再决定是否另建版本化参考集；现有官方参考与基线分数保持不变。

### 证据与适用范围

本轮证据位于本机临时产物目录，没有把音频或完整识别输出提交到仓库：

- [12 个单测日志](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-unit-01.log)、[Release 构建日志](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-build-02.log)。
- [CER 报告](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-run-01/cer.json)、[逐条参考与输出](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-run-01/comparisons.json)、[原始窗口结果](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-run-01/utterances.jsonl)。
- [独立审计脚本](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/audit_quality_run_01.py)、[审计结果与最差 20 条完整窗口](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/quality-run-01-audit.json)。

| 身份 | SHA-256 |
| --- | --- |
| 测量时源代码 | `97dc709eb489b7c5fd03fdededea7590b9a728dc4f16e4222b080557f40b00d8` |
| `run.json` | `88c10d5c13fc81186904c47a91b68ff001d4f7a11a9eabe8acc6b1b2c02c5216` |
| `utterances.jsonl` | `33d7453a9cb7ec08ab56318173b6e1673e3dce51738d58334ec152dd6596ef07` |

`run.json` 还保存模型哈希与配置指纹。这份成绩限定为 Mac、逐文件、公开朗读语音的 CER 基线，不能外推到 iPhone 速度或耗电、连续录音窗口、腕部声学表现及后台执行。VAD 漏检率、实体准确率和人工语音区间仍待标注；剩余 30 分钟候选尚未运行。报告保留 `acceptance=not_evaluated`，Release 构建通过和本次 CER 均不表示发布质量达标。
