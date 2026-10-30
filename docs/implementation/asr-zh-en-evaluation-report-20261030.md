# 中英混说 ASR 评测报告（2026-10-27 ～ 10-30）

本报告汇总 MoMo Agent 端侧 ASR 的中英混说评测。我们先在 Mac 上用两个公开数据集离线比较了 20 多个模型和变体，包括 FireRedASR2-AED 的多种压缩版本；再挑出 8 个模型，在 iPhone 上用 App 自己的识别引擎实测。报告供后续选择和接入 ASR 模型时参考，不改动 App 代码。第 0～5 节是结论和主要数字，附录保留各轮实验的完整细节、复现命令和原始产物位置。

## 0. 结论

- **推荐把 X-ASR 非流式 INT8 作为中英混说的可选模型。** 体积 167 MiB，Mac 上三个混说集的 MER 为 12.2% / 5.9% / 4.7%（ASCEND / CS-Dialogue test / dev），与准确率最高的 FireRed AED INT8 没有显著差异，比当前默认的 SenseVoice 显著更好（低 1.7～2.3 个百分点）。iPhone 上峰值内存 0.54 GiB，RTF 0.021，一天 8 小时录音约 1.5 分钟转写完；手机和 Mac 的结果一致。它只支持中文和英文，所以适合作为可选下载，接入另提 PR。App 将固定的 HF 逐文件版本与评测用的 GitHub 归档逐字输出相同（见第 2 节）。
- **SenseVoice 继续作为默认模型。** 支持粤语、日语、韩语，体积小、速度快，并且在神经网络引擎上运行。
- **FireRedASR2-AED 最准，但还不能直接放进 App。** 4 bit 量化版（块 32，786 MiB）与 INT8 原版准确率无差异（11.3% / 5.3% / 4.5%），体积小三分之一。iPhone 前台能跑，峰值内存 1.2～1.7 GiB；但它全程占满 CPU，在音频后台模式下约 70 秒就被 iOS 的 CPU 限制终止（60 秒内平均 80% CPU）。Nano 也一样。要用它，须先确认转写能在不受此限制的后台任务中运行，或者限速，并实测。
- **已知问题：后台 CPU 限制对所有 CPU 模型都存在。** 实测中 X-ASR、Paraformer、SenseVoice 的后台一轮只解码约 11 分钟语音，14～32 秒就跑完，所以没有触发限制；它们解码时同样占用 150%～200% CPU。积压较多、需要连续解码超过约半分钟时，在音频后台模式下也可能被终止。这一点对蓝牙耳机录音（靠音频后台模式保活）尤其重要，须在真实 App 中验证。
- **不推荐：** Core ML 4 bit FireRed（fp16 计算损失 3～7 个百分点）、Qwen3-ASR 0.6B / 1.7B（翻译式改写、失控、体积大）、Apple 系统识别（英文差）、Whisper、Dolphin、FireRed CTC 及两个方言微调版。X-ASR 流式版准确率低一档，留作以后实时功能的候选。
- **待服务器：** FireRedASR2-LLM（约 80 亿参数）在 Mac 上跑不动，需要约 24 GB 显存的 GPU，脚本已备好。
- **数据局限：** FireRed、Nano、Qwen3、X-ASR 都发布于 CS-Dialogue 公开之后，不能排除训练时见过它，它们在该数据集上的成绩应视为上限。两个数据集都不是用户本人的录音，真实录音上的绝对错误率会不同。

## 1. 怎么测的

### 为什么只测中英混说

MoMo Agent 的用户日常说话以普通话为主，夹杂英文单词和短语，例如「我明天要去 meeting 讨论 project 的 deadline」。这类句子是现有 SenseVoice 最常出错的地方：英文词被截断、拼错，或被写成同音汉字。所以主指标只看**同一句里既有中文又有英文**的混说句，纯中文和纯英文句只作对照。

### 两个数据集

| 数据集 | 内容 | 本次使用 | 许可 |
| --- | --- | --- | --- |
| [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)（港科大 CAiRE） | 香港高校学生的自然对话，噪声和口音较重 | 混说 400 条（test 200 + validation 200，5 位说话人），另有纯中文、纯英文各 50 条；共 500 条、32.9 分钟 | CC BY-SA 4.0 |
| [CS-Dialogue](https://huggingface.co/datasets/BAAI/CS-Dialogue)（BAAI） | 普通话—英语对话，录音条件较好，说话人英语水平较高 | test 混说 730 条（30 人）、dev 混说 781 条（30 人），只取不超过 20 秒的句子；另从 test 各抽 300 条纯中文、纯英文对照；共 2,111 条 | CC BY-NC-SA 4.0，附加条款：仅限非商业研究，不得再分发。**仓库只提交句子编号**（`Tools/ASRCodeSwitchEval/csd-eval-ids-v1.json`），音频、参考文本和识别结果都不提交、不外传 |

只用 20 秒以内的句子，是因为 App 送给 ASR 的窗口最长 20 秒。用户已于 2026-10-27 同意 CS-Dialogue 的条款。TALCS 已无法从官方获取，没有使用。数据集细节见[附录 C](#附录-c数据集)。

### 错误率（MER）怎么理解

MER（混合错误率）把汉字按字、英文按词计数，看模型输出与人工参考相比错了多少：

> MER = （替换 + 删除 + 插入）÷ 参考的总字词数

例如参考是「我明天要去 meeting」，共 6 个单位（我、明、天、要、去、meeting）。模型输出「我明天要去 meet in」，替换 1 个、插入 1 个，MER = 2 / 6 ≈ 33%。数值越低越好。比较前，参考和输出都做同样的规范化：繁体转简体、去掉标点和语气词（呃、嗯、um 等）、数字统一读法、大小写统一。细节见[附录 D](#附录-d规范化与指标momo-cs-mer-v1)。

**失控**指输出远长于语音内容（字词数超过参考的 2 倍再加 10），通常是同一短语反复循环。

### 怎么判断「显著」

同一批句子上，两个模型的 MER 差值会受句子抽样影响。我们用**配对 bootstrap**：对句子做有放回的重新抽样 2,000 次（固定种子 20261027），每次在同一组句子上算两个模型的 MER 差，取中间 95% 作为差值区间。

- 区间整体小于 0（例如 −3.1…−1.4），说明前者显著更好；整体大于 0 则显著更差。
- 区间跨过 0（例如 −0.6…+1.3），说明在这些数据上分不出差别。
- ASCEND 的参考本身有误标，1 个百分点以内的差异不应解读为模型差异。

## 2. Mac 离线结果

所有模型使用同一套语料、规范化和评分脚本（`Tools/ASRCodeSwitchEval/score.py`，`momo-cs-mer-v1`）。sherpa-onnx 模型都用 CPU、2 线程、greedy 解码，与 App 默认设置一致。MER 单位为 %，按 ASCEND 混说 MER 排序。

| 模型 | 体积 | ASCEND 混说 | CSD test 混说 | CSD dev 混说 | 失控 | RTF | 峰值内存 | 测速批次 |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | :---: |
| FireRedASR2-AED int4 块 32（自行量化） | 786 MiB | **11.3** | **5.3** | **4.5** | 0 / 0 | 0.237 | 1,831 MiB | B |
| FireRedASR2-AED INT8 编码器 + int4 解码器（自行量化） | 1,044 MiB | 11.4 | **5.3** | **4.5** | 0 / 0 | 0.330 | 2,756 MiB | B |
| **FireRedASR2-AED INT8**（官方） | 1,177 MiB | 11.8 | 5.6 | **4.5** | 0 / 0 | 0.341 | 2,909 MiB | B |
| FireRedASR2-AED int4 块 128（自行量化） | 671 MiB | 12.0 | 5.9 | **4.5** | 0 / 0 | 0.214 | 1,473 MiB | B |
| **X-ASR 非流式 INT8**（官方） | **167 MiB** | 12.2 | 5.9 | 4.7 | 0 / 0 | **0.020** | 713 MiB | B |
| Qwen3-ASR 1.7B（官方包，MPS bf16） | 4,485 MiB | 12.8 | 8.1 | 5.4 | 0 / 1 | 0.326 | 2,865 MiB（footprint 最高 20 GB） | B |
| FunASR Nano INT8（App 新运行时） | 963 MiB | 13.2 | 6.7 | 5.1 | 0 / 0 | 0.114 | 2,383 MiB | N |
| FunASR Nano INT8 + 失控保护（离线模拟） | 963 MiB | 13.3 | 6.6 | 5.6 | 0 / 1 | 0.170 | 3,405 MiB | A |
| X-ASR 流式 480 ms INT8（官方） | 161 MiB | 14.0 | 7.5 | 6.2 | 0 / 0 | 0.071 | 491 MiB | B |
| **SenseVoice Small INT8**（App 默认，基线） | 229 MiB | 14.5 | 8.2 | 6.4 | 0 / 0 | 0.031 | 1,055 MiB | A |
| Qwen3-ASR 0.6B INT8 | 941 MiB | 14.7 | 11.8 | 8.8 | 0 / 4 | 0.197 | 2,913 MiB | A |
| SenseVoice INT8（固定 zh） | 229 MiB | 15.4 | — | — | 0 / — | 0.045 | 1,054 MiB | A |
| Paraformer zh 2024-03-09 INT8 | 217 MiB | 15.8 | 7.3 | 6.0 | 0 / 0 | 0.023 | 981 MiB | A |
| FunASR Nano INT8（固定中文，旧 App 解码） | 963 MiB | 16.5 | — | — | 1 / — | 0.239 | 2,675 MiB | A |
| FunASR Nano INT8（旧 App，sherpa 内置解码） | 963 MiB | 17.3 | 8.3 | 6.8 | 1 / 4 | 0.170 | 3,405 MiB | A |
| SenseVoice 粤语微调 2025-09-09 | 226 MiB | 17.6 | — | — | 0 / — | 0.037 | 1,049 MiB | A |
| FireRedASR2-AED Core ML 4 bit 查表，fp16 计算（自行转换） | 601 MiB | 18.6 | 9.1 | 8.9 | 0 / 1 | 0.232 | footprint 1.6 GB | B |
| FireRedASR2-CTC INT8 | 740 MiB | 19.1 | — | — | 0 / — | 0.248 | 2,091 MiB | A |
| Apple `SpeechTranscriber` zh-CN | 系统资源 363 MiB | 19.7 | 10.9 | 9.4 | 0 / 0 | 0.028 | 系统进程 | B |
| Whisper large-v3-turbo INT8 | 988 MiB | 28.1 | — | — | 0 / — | 0.633 | 2,985 MiB | A |
| Paraformer 川话微调 2025-10-07 | 227 MiB | 36.8 | — | — | 0 / — | 0.024 | 995 MiB | A |
| Dolphin small CTC INT8 | 239 MiB | 42.5 | — | — | 0 / — | 0.038 | 988 MiB | A |
| Apple `SpeechTranscriber` en-US（参照） | 系统资源 392 MiB | 84.6 | 86.3 | 86.3 | 0 / 0 | 0.029 | 系统进程 | B |
| FireRedASR2-LLM | 18.9 GB | — | — | — | — | 2.96（20 条试跑） | footprint 25.4 GB | B |

- **失控**列为 ASCEND 混说 400 条 / CS-Dialogue 混说 1,511 条中的失控句数。「—」表示未在该数据集上运行：明显不合格的模型只跑了 ASCEND。
- **RTF**（解码时间 ÷ 音频时长，越低越快）和峰值内存都在 ASCEND 500 条、单进程上测得，不含模型加载。**测速批次**：A 为 10-27，本机同时有 Xcode 构建；B 为 10-29，全程用电池并开启低电量模式，部分时间机器睡眠，INT8 原版在同一条件下重跑，以便与量化变体公平比较；N 为 10-29 的 Nano 新运行时，用电池和低电量模式。**RTF 只适合在同一批次内比较**，不代表 Mac 的绝对速度，也不能换算成 iPhone 耗时（见第 4 节）。
- 各模型的置信区间、纯中文 / 纯英文对照、错误示例见附录 E。

**各类模型简评：**

- **FireRedASR2-AED：** 两个数据集上都最准，中文和句中英文两项都最好；三个混说集上都显著优于 SenseVoice（差值 −3.7…−1.5 个百分点）。代价是体积和 CPU 计算量最大。输出没有标点，英文全大写。压缩版本见第 3 节。
- **X-ASR（2026-06 发布，Apache-2.0）：** 同一个约 1.6 亿参数的 Zipformer 模型，有非流式和流式两种导出。非流式版与 FireRed INT8 在三个混说集上的差值区间都包含 0（ASCEND −0.6…+1.3，CSD test −0.1…+0.7，dev −0.2…+0.7），体积约为其 1/7，耗时约为其 1/17；输出带标点和大小写。典型错误是短英文词写成同音汉字，例如 “latte” 写成「辣脆」。流式版差一档，末尾须补约 2 秒静音才不丢句末的词。
- **FunASR Nano：** 旧 App 的解码会陷入重复循环；App 换成自带运行时后失控为 0，三个混说集都显著优于 SenseVoice。删除错误比旧版多，需要在真实录音上留意漏词。
- **SenseVoice（默认）：** 速度快、体积小，纯英文表现好；混说句里英文词常被截断或拼错。固定为普通话会更差，应保持自动识别。
- **Paraformer：** 在 CS-Dialogue 混说上略好于 SenseVoice，在 ASCEND 上略差，纯英文明显更差，不值得替换。
- **Qwen3-ASR：** 会把混说句整句意译成英文或中文，不是逐字转写，并有失控。1.7B 比 0.6B 好很多，但仍不如 FireRed，体积 4.5 GB。
- **Apple `SpeechTranscriber`：** 中文部分与 SenseVoice 相当，句中英文 WER 达 44%～58%；没有中英混合的语言选项。系统自带、零下载、很快，可以考虑作为纯中文兜底。
- **其他：** Whisper、Dolphin、FireRed CTC 和两个方言微调版都明显差于基线，只在 ASCEND 上评测。

**X-ASR 的 App 下载版本复测（2026-10-30）：** App 的模型安装器逐个下载文件并校验 SHA256，不能使用 GitHub 上的整包归档，所以 App 要固定 HF 镜像 `csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03` @ `ce812cc0`。镜像中的编码器（`fe0198b5…`，161,744,450 字节）和解码器（`a9fe7c32…`）与归档中的文件（`7f6aa620…` / `72f47405…`）是同一模型的另一次导出；joiner、`bpe.model`、`tokens.txt` 两边相同。用镜像文件在两个数据集上重跑全部 2,611 条（运行名 `x-asr-offline-punct-int8-20260603-hf`），**每一条输出都与归档版本逐字相同**，MER 完全一致（ASCEND 12.2%，CSD test 5.9%，dev 4.7%，配对差值 +0.0…+0.0）。因此本报告中 X-ASR 非流式版的结论同样适用于 App 将下载的文件。

## 3. 压缩版本

FireRedASR2-AED 最准但最大，所以试了几种减小体积的方法。官方只发布了 INT8 版（1,177 MiB）；下表的 4 bit 版本都是我们从官方 fp32 文件或 PyTorch 权重自行生成的，脚本和哈希已固定（`quantize_firered.py`、`firered_coreml.py`；每个模型目录有 `quantize.json`）。Δ 为相对 INT8 原版的 MER 差值，配对 bootstrap 95% 区间，负数表示更好。

| 变体 | 体积（相对 INT8） | ASCEND 混说（Δ） | CSD test 混说（Δ） | CSD dev 混说（Δ） | Mac RTF | 峰值内存 |
| --- | ---: | --- | --- | --- | ---: | ---: |
| INT8 原版（官方，基线） | 1,177 MiB | 11.8 | 5.6 | 4.5 | 0.341 | 2,909 MiB |
| (a) ONNX int4，块 32 | 786 MiB（−33%） | 11.3（−1.1…+0.0） | 5.3（−0.5…−0.0） | 4.5（−0.3…+0.3） | 0.237 | 1,831 MiB |
| (a) ONNX int4，块 128 | 671 MiB（−43%） | 12.0（−0.4…+0.7） | 5.9（−0.2…+1.1） | 4.5（−0.4…+0.2） | 0.214 | 1,473 MiB |
| (b) INT8 编码器 + int4 解码器 | 1,044 MiB（−11%） | 11.4（−0.9…+0.1） | 5.3（−0.5…−0.1） | 4.5（−0.2…+0.3） | 0.330 | 2,756 MiB |
| (c2) Core ML 4 bit 查表，fp16 计算 | 601 MiB（−49%） | 18.6（+4.8…+9.3） | 9.1（+2.8…+4.3） | 8.9（+3.3…+5.8） | 0.232 | footprint 1.6 GB |
| 对照：Core ML fp16，未量化 | 2,215 MiB | 19.0（+4.5…+10.4） | — | — | 0.237 | footprint 1.6 GB |
| 对照：Core ML fp32 计算，未量化 | 4,428 MiB | 12.1（−0.3…+1.0） | — | — | 0.407 | footprint 1.6 GB |
| (c3) Core ML 4 bit 查表，fp32 计算 | 661 MiB（−44%） | 13.0（+0.4…+2.0） | — | — | 0.412 | footprint 1.6 GB |

- **ONNX 4 bit 没有可测的准确率损失。** (a)(b) 三个变体在三个混说集上的区间都包含 0 或在 0 以下，都没有失控，sherpa-onnx 1.13.8（App 使用的版本）可以直接加载。做法：先把编码器中 635 MB 的 1×1 卷积等价改写为 MatMul（fp32 下逐位相同），再用 ONNX Runtime `MatMulNBits` 做 4 bit 按块量化（`accuracy_level=4`）；否则这部分权重会留在 fp32，4 bit 编码器反而比 INT8 更大。
- **Mac 上的速度和内存收益主要来自编码器：** 全模型 int4（块 32）RTF 降 31%，内存降 37%；只量化解码器的 (b) 几乎没有收益。**但在 iPhone 上 int4 并不比 INT8 快**，见第 4 节。
- **Core ML 版的损失来自 fp16 计算，而不是 4 bit。** 未量化的 fp16 版同样差约 7 个百分点；按 fp32 计算时转换本身正确（12.1%），4 bit 查表只多损失约 1 个百分点（13.0%）。iPhone 的神经网络引擎只做 fp16 计算，所以 Core ML 路线需要先解决 fp16 数值问题（让 LayerNorm、softmax、注意力分数保持 fp32），再把可变长度输入改为固定长度分桶，估计 1～2 天，目前不做。int4 线性量化的 Core ML 版（c1）只能在 GPU 上运行，完整评测时卡在 MPSGraph 编译，没有结果。
- **项目约定：** App 目前只使用上游官方发布的模型文件并核对 SHA256，不自行量化。自行量化的版本若要进入 App，需要先与项目负责人确认，并记录来源、脚本和哈希。

## 4. iPhone 实测

### 测试方法

从 Mac 结果中选出 8 个模型，在 iPhone 17 Pro Max（iOS 26.7.1）上实测。目的不是重新给准确率排名，而是确认**每个模型能否在 App 的真实条件下运行**。

- **测试 App：** `Tools/ASRCodeSwitchEval/iPhoneBench/` 是一个单独的小 App，不改动正式 App。它直接链接正式 App 的识别引擎（`Vendor/SherpaOnnx` 的 `MoMoSherpaBridge`：sherpa-onnx 1.13.8 + ONNX Runtime 1.28.2，2 线程）。SenseVoice 使用 App 的 Core ML 设置（`CPUAndNeuralEngine`、静态形状、模型缓存），Nano 使用 App 自带的 Nano 运行时，其余模型走 CPU。8 个模型都能用 App 的引擎加载，不需要换用官方引擎。
- **音频：** 约 31 分钟真实耳机录音（用户本人的录音，只在本机与手机之间传输，不提交）。用 App 自己的 VAD 和窗口规划切成 221 个识别窗口，与 App 实际送给 ASR 的输入相同。另有 100 条 ASCEND 混说句，用于核对手机与 Mac 的结果。CS-Dialogue 没有放到手机上。
- **三轮：** 每个模型分别跑 ASCEND 100 条（前台）、真实录音 221 个窗口（前台）、真实录音前 80 个窗口（约 11 分钟语音，后台）。后台一轮用静音音频保持 App 在后台运行，与蓝牙耳机录音保活的方式相同（音频后台模式）。
- **指标：** 能否完成、冷启动加载时间、RTF、峰值内存（`phys_footprint`）与剩余可用内存（`os_proc_available_memory`）、CPU 时间、热状态。手机全程充电，不测耗电。
- **一天 8 小时录音的折算：** 在用户 7.4 小时的录音上，App 的 VAD 只保留约 13.9% 作为识别窗口，所以 8 小时录音约对应 1.1 小时需要识别的音频。

### 结果

| 模型 | 前台 | 后台 | 峰值内存 前台 / 后台 | 最少剩余内存 | 冷启动加载 | RTF 前台 / 后台 | 8 小时录音约需 | 100 句 MER 手机 / Mac |
| --- | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| SenseVoice（默认，Core ML EP） | ✅ | ✅ | 0.71 / 0.58 GiB | 2.58 GiB | 16.1 s（缓存后 4.2 s） | 0.039 / 0.031 | 约 3 分钟 | 15.7 / 15.7 |
| FunASR Nano（App Nano 运行时） | ✅ | ❌ CPU 超限 | 1.47 GiB / — | 1.83 GiB | 1.4 s | 0.140 / — | 约 9 分钟 | 15.5 / 14.8 |
| FireRed AED INT8 | ✅ | ❌ CPU 超限 | 1.70 GiB / — | 1.60 GiB | 1.2 s | 0.365 / — | 约 24 分钟 | 14.3 / 14.0 |
| FireRed AED int4 块 32 | ✅ | ❌ CPU 超限 | 1.32 GiB / — | 1.98 GiB | 1.2 s | 0.421 / — | 约 28 分钟 | 13.0 / 12.8 |
| FireRed AED int4 块 128 | ✅ | ❌ CPU 超限 | 1.20 GiB / — | 2.09 GiB | 1.1 s | 0.378 / — | 约 25 分钟 | 13.7 / 13.6 |
| **X-ASR 非流式** | ✅ | ✅ | 0.54 / 0.54 GiB | 2.76 GiB | 1.1 s | 0.021 / 0.020 | 约 1.5 分钟 | 13.0 / 13.3 |
| X-ASR 流式 480 ms | ✅ | ✅ | 0.34 / 0.34 GiB | 2.95 GiB | 0.9 s | 0.050 / 0.047 | 约 3.5 分钟 | 14.8 / 14.3 |
| Paraformer | ✅ | ✅ | 0.32 / 0.32 GiB | 2.98 GiB | 0.5 s | 0.024 / 0.024 | 约 1.5 分钟 | 19.2 / 19.0 |

- **内存不是瓶颈。** 前台可用上限约 3.3 GiB（峰值 + 剩余），8 个模型峰值最多 1.70 GiB，剩余都在 1.6 GiB 以上。
- **手机与 Mac 结果一致。** 同样 100 句上 MER 相差不超过 0.7 个百分点，int4 量化版在手机上同样正确。100 句太少，只用于核对一致性，不用于排名。
- **速度本身不是瓶颈：** 8 小时录音最慢约半小时转写完。

### 后台 CPU 限制

Nano 和三个 FireRed 版本在后台一轮都在约 72 秒时被 iOS 终止。崩溃报告为 `cpu_resource_fatal`：48 秒内用了 48 秒 CPU（平均 100%），超过「60 秒内 80% CPU」的限制，处理方式为终止进程。终止前，Nano 完成了 63/80 个窗口，FireRed 完成了 31～34 个。期间内存始终充足，原因只是 CPU。

其余四个模型没有被终止，但要注意原因：它们的后台一轮在 14～32 秒内就做完了 80 个窗口，CPU 总量为 25～48 秒，还没持续到 60 秒的统计窗口。所有模型解码时都占用约 150%～200% CPU（2 线程），X-ASR 也一样。**一次要连续解码的音频更多时，任何 CPU 模型在音频后台模式下都可能触发同样的限制。** 本次没有测试这种长时间积压的情形。

与 App 的关系：

- App 现有的后台转写主要通过 `BGProcessingTask` 进行（见[后台转写](background-transcription.md)）。该路径本次没有测试，不能据此断定它是否受同一限制。
- 蓝牙耳机录音靠音频后台模式保持 App 运行。如果在这种状态下转写，就会受上述限制，而 App 被终止会连带中断录音。接入任何新模型前，都应在真实 App 中验证这一场景。
- App 在热状态为 serious 或 critical 时不接纳后台转写，而本次测试中手机大部分时间处于 serious（见下）。

### 测量条件与注意事项

- **热状态：** 手机一边充电一边连续运行，大部分运行处于 serious，只有最早几轮为 nominal 或 fair。热降频会拉低速度，所以表中 RTF 偏保守；不同模型所处的热状态也不完全相同。
- **FireRed int4 在 iPhone 上不比 INT8 快**（RTF 0.421 / 0.378 对 0.365），与 Mac 上相反。INT8 一轮开始时热状态为 fair，两个 int4 版本全程为 serious，这会造成一部分差别；另一部分可能来自 `MatMulNBits` 在 iPhone CPU 上的内核表现。可以确定的是，int4 在手机上能省约 0.4～0.5 GiB 内存，但省不了时间。
- **SenseVoice 首次运行要编译 Core ML 模型：** 第一轮加载 16.1 秒；第一次跑真实录音时，每遇到新的输入长度都要编译，RTF 高达 1.37。用已编译的缓存重跑后，加载 4.2 秒、RTF 0.039，上表用的是重跑结果。App 会缓存编译结果（`ModelCacheDirectory`），所以只有第一次慢。
- 后台一轮只取前 80 个窗口；被终止的模型没有后台 RTF。

## 5. 建议与后续

1. **把 X-ASR 非流式 INT8 作为可选模型接入 App（另提 PR）。** 做法与 FunASR Nano 相同：固定 HF 镜像 `ce812cc0` 的文件及其 SHA256，用户在设置中下载并启用，默认仍为 SenseVoice。它只支持中文和英文，语言设置为粤语、日语、韩语时不提供。许可证为 Apache-2.0，需加入 App 的模型声明。接入后在真实 App 中验证后台转写，特别是蓝牙耳机录音期间。
2. **FireRedASR2-AED（准确率最高）暂不接入。** 先要解决后台 CPU 限制：确认 `BGProcessingTask` 下能否长时间运行，或者限速，让平均 CPU 低于 80%。若要用 int4 版，还需项目负责人同意使用自行量化的文件。
3. **FireRedASR2-LLM 上限参考：** 在约 24 GB 显存的 GPU 服务器上运行，命令见[附录 E4 第 5 节](#5-fireredasr2-llm)。
4. **X-ASR 流式版留作以后实时功能的候选**（实时字幕、语音指令等）：手机上 0.34 GiB、RTF 0.05，准确率比非流式版低约 1.5～2 个百分点。
5. **真实录音上的准确率：** 公开数据集不能代表用户本人的口音、用词和耳机音质，之后可用人工校对的真实录音片段补测。

## 附录

| 附录 | 内容 |
| --- | --- |
| A | 运行环境 |
| B | 候选模型的来源、校验与许可 |
| C | 数据集与抽样细节 |
| D | 规范化与指标定义 |
| E | 各轮详细结果：E1 ASCEND 首轮，E2 CS-Dialogue，E3 App 新 Nano 运行时，E4 扩展评测（X-ASR、Apple、Qwen3 1.7B、FireRed 量化、FireRedASR2-LLM）；含错误示例 |
| F | 实验经过与各轮当时的结论 |
| G | 复现命令 |
| H | 原始产物位置 |

### 附录 A：运行环境

| 项目 | 值 |
| --- | --- |
| 机器 | Apple M5，24 GB，macOS 26.6（25G72） |
| Python 推理 | `uv` 隔离环境，CPython 3.12.15，`sherpa-onnx==1.13.8`（PyPI，内置 ONNX Runtime 1.28.2，与 App 固定版本相同），`numpy==2.3.4` |
| 评分 | `opencc-python-reimplemented==0.1.7`（繁转简），其余为标准库 |
| 执行方式 | CPU provider，`num_threads=2`（与 App 的 `SpeechConfiguration` 默认值一致），greedy search，每个模型单独一个进程 |
| Swift 对照 | Xcode 27.1，Swift 6.4，`Tools/SpeechQuality` Release 构建；固定 Core ML 运行库 `sherpa-coreml-1.13.8-wml.1`（经 `prepare-runtime.py`、`gh` 下载并校验） |
| 并发负载 | 测速期间本机另有 Xcode/Swift 构建在运行（1 分钟 load average 约 2.2～5.3）。**RTF 和内存只作参考**；准确率不受影响。 |

App 中 SenseVoice 的静态子图和 Nano 的编码器走 Core ML EP，本实验统一走 CPU，因此数值会有极小差异。下文的 Swift 对照说明这部分差异可以忽略。

### 附录 B：候选模型

所有权重均为 sherpa-onnx 官方转换包，没有重新量化。凡上游公布了 SHA256（GitHub release asset digest，或 Hugging Face LFS oid）的文件，均已逐一校验。

| 运行名 | 发布文件 / 修订 | 校验 | 上游与许可 | 实际使用文件大小 | 语言设置 |
| --- | --- | --- | --- | ---: | --- |
| `sensevoice-int8-20240717`（基线） | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2` | 归档 `7d1efa21…`；`model.int8.onnx`、`tokens.txt` 与 App 的 `Native/SpeechVendor/manifest.json` 一致 | FunAudioLLM/SenseVoiceSmall，FunASR 模型许可 v1.1 | 229 MiB | `auto`，ITN 开（同 App） |
| `funasr-nano-int8-20251230` | HF `csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30` @ `6f16bd37…` 的 6 个文件 | 与 App 下载清单 `funasr-nano-onnx-v1.json` 的 6 个 SHA256 一致 | Fun-ASR-Nano-2512，Apache-2.0 | 963 MiB | 语言为空（自动）、ITN 开，提示词、`max_new_tokens=384`、`temperature=0` 均同 App |
| `qwen3-asr-0.6b-int8-20260325` | `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2` | 归档 `393f8a14…` | Qwen/Qwen3-ASR-0.6B，Apache-2.0；ONNX 由第三方 `zengshuishui/Qwen3-ASR-onnx` 导出，sherpa 官方转发 | 941 MiB | sherpa 接口不提供语言参数（自动）；`max_new_tokens=256` |
| `fireredasr2-aed-int8-20260226` | `sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26.tar.bz2` | 归档 `43015b3f…` | FireRedTeam/FireRedASR2-AED，Apache-2.0 | 1,177 MiB | 无语言参数（中英模型） |
| `fireredasr2-ctc-int8-20260225` | `sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2` | 归档 `1da8b737…` | 同上，只用编码器和 CTC 分支 | 740 MiB | 无 |
| `paraformer-zh-int8-20240309` | `sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2`，使用其中的 `model.int8.onnx` | GitHub 无 digest；`model.int8.onnx` 与 HF `csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09` @ `906992d3` 的 LFS oid 一致 | ModelScope `iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8358-tensorflow1`（v1.1.9，中英）。包内 README 写的是参照 FunASR 仓库许可；HF `funasr/paraformer-zh` 标注 Apache-2.0。若要随产品分发，须先核对 FunASR 模型许可 | 217 MiB | 无 |
| `paraformer-zh-int8-20251007` | `sherpa-onnx-paraformer-zh-int8-2025-10-07.tar.bz2` | 归档 `a071ee54…` | **四川话微调版** ASLP-lab/WSChuan-ASR，Apache-2.0。不是新版通用中英模型 | 227 MiB | 无 |
| `sensevoice-int8-20250909` | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` | 归档 `7305f790…` | **粤语微调版** ASLP-lab/WSYue-ASR，Apache-2.0。不是 SenseVoice 官方更新 | 226 MiB | `auto`，ITN 开 |
| `dolphin-small-ctc-int8-20250402` | `sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02.tar.bz2` | GitHub 无 digest；`model.int8.onnx` 与 HF LFS oid `c1afcb92…` 一致 | DataoceanAI/dolphin-small，Apache-2.0 | 239 MiB | 无（自动） |
| `whisper-large-v3-turbo-int8` | `sherpa-onnx-whisper-turbo.tar.bz2`，使用其中的 INT8 编码器和解码器 | GitHub 无 digest；两个 INT8 文件与 HF `csukuangfj/sherpa-onnx-whisper-turbo` @ `2ca6ff69` 的 LFS oid 一致 | openai/whisper-large-v3-turbo，MIT | 988 MiB | 语言为空（自动检测），`task=transcribe` |

另外运行了两个“固定普通话”变体，复用对应模型的文件：`sensevoice-int8-20240717-lang-zh`（`language=zh`）和 `funasr-nano-int8-20251230-lang-zh`（`language=中文`）。完整清单和逐文件 SHA256 保存在 `tmp_agent_output/asr-code-switching-eval/models/*.fetch.json`；文件名、URL 与哈希固定在 `Tools/ASRCodeSwitchEval/models.py`。

#### 未运行的候选

| 候选 | 原因 |
| --- | --- |
| Qwen3-ASR 1.7B | sherpa-onnx 官方 `asr-models` release 只有 0.6B INT8，作者的 HF 账号下也没有 1.7B 导出。HF 上的 `ilmina/qwen3-asr-1.7b-sherpa-onnx` 是第三方上传，没有 README、来源和哈希，按“不使用来源不明的权重”规则跳过。如需上限参考，可以用 sherpa 的导出脚本，从官方 `Qwen/Qwen3-ASR-1.7B`（Apache-2.0）自行导出。**2026-10-29 已用官方 `qwen-asr` 包和官方权重在 MPS 上补跑**，见[扩展评测第 3 节](#3-qwen3-asr-17b官方-qwen-asr-包)。 |
| FireRedASR v1（`fire-red-asr-large-zh_en-2025-02-16`，1.47 GB） | 已由同团队的 v2 AED 代替，没有重复运行。 |
| NVIDIA Parakeet CTC 0.6B zh-cn | HF 上没有公开权重（只能在 NVIDIA NIM/Riva 中使用），也没有 sherpa 导出，按要求只做记录。 |
| NVIDIA Nemotron ASR | 只支持英文，按要求跳过。 |
| Whisper 固定 `zh` 变体 | Whisper 在 sherpa 中会把短句补齐到 30 秒，每条约需 2.5 秒，全量约 20 分钟。自动检测结果已远落后于基线，固定语言不会改变推荐，因此没有运行。 |

### 附录 C：数据集

| 数据集 | 状态 | 许可 |
| --- | --- | --- |
| [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)（HKUST CAiRE，自然对话） | **已使用**。revision `737e9800ae31be9932ba8464c80366559bd28424`。test parquet SHA256 `a4c81d2b…`，validation parquet SHA256 `3bdec53d…`，均与 HF LFS oid 一致 | CC BY-SA 4.0 |
| [CS-Dialogue](https://huggingface.co/datasets/BAAI/CS-Dialogue)（BAAI，arXiv 2502.18913） | 首轮未下载：数据卡要求申请并同意条款。**用户于 2026-10-27 同意条款后已下载并复测**，见 [CS-Dialogue 复测](#附录-e2cs-dialogue-复测2026-10-27-晚)。 | CC BY-NC-SA 4.0，附加条款：仅限学术/非商业、不得再分发、受试者撤回时须删除 |
| TALCS（TAL，arXiv 2206.13135） | **无法获取。** 论文脚注指向 `https://ai.100tal.com/dataset`，2026-10-27 该页只列出 HME100K 和 K-12 印刷体两个数据集，没有 TALCS。HF、ModelScope、OpenSLR 上也没有官方镜像。没有使用非官方来源。 | 论文称 “permissive license”，具体条款无法确认 |

#### 抽样（`momo-ascend-cs-v1`）

`Tools/ASRCodeSwitchEval/corpus.py` 先按 ID 排序，再用固定种子 `20261027:<subset>` 抽样。只保留时长 ≥ 1 秒、并且去掉 `[UNK]` 与语气词后仍有内容的句子。抽样过程不读取任何模型输出。确切 ID 已提交在 `Tools/ASRCodeSwitchEval/ascend-sample-v1.json`。

| 子集 | 来源 | 抽取 / 合格 | 时长 | 中位句长 | 说话人 |
| --- | --- | ---: | ---: | ---: | --- |
| `ascend-test-mixed` | test，`language=mixed` | 200 / 369 | 14.2 min | 3.7 s | 2 人（3、17） |
| `ascend-val-mixed` | validation，`mixed` | 200 / 210 | 14.7 min | 3.8 s | 3 人（7、12、20） |
| `ascend-test-zh`（对照） | test，`zh` | 50 / 410 | 1.9 min | 1.9 s | 同 test |
| `ascend-test-en`（对照） | test，`en` | 50 / 168 | 2.1 min | 2.0 s | 同 test |

总计 500 条，32.9 分钟，全部为 16 kHz、单声道 PCM16，直接按整句输入模型，没有经过 VAD。混说结果以两个混说子集合并后的 400 条（`ascend-mixed-all`）为主。

### 附录 D：规范化与指标（`momo-cs-mer-v1`）

参考文本和所有模型的输出使用同一套处理，实现在 `Tools/ASRCodeSwitchEval/score.py`：

1. Unicode NFKC 与 casefold；删除 `[UNK]`、`<|en|>` 等标签。
2. 繁体转简体（OpenCC t2s）。Whisper 有 60 条输出为繁体。
3. **数字读法：** ASCEND 参考中没有阿拉伯数字。数字紧邻汉字时转成中文读法（“100多”→“一百多”，“95%”→“百分之九十五”，“2019年”→“二零一九年”）；两侧只有英文单词时转成英文读法（“80 students”→“eighty students”，“2030”→“twenty thirty”，“105”→“one hundred and five”）；两侧都没有文字时按中文。“两”统一为“二”，使“两门”与 ITN 输出的“2门”等价。每个模型输出中含数字的句数单独列出（SenseVoice 16 条，Whisper 11 条，其余 ≤ 3 条）。
4. 标点和符号视为空格，词内撇号保留；`okay` 视为 `ok`。
5. 连续两个及以上的单字母合并为一个词，例如参考 “i s m” 与输出 “ISM” 等价。
6. **主指标去掉语气词**（呃、嗯、啊、哦、噢、唉、诶、欸、哎、额、呣，um、uh、uhm、hmm、mm、mhm、er、ah、oh、eh），参考和输出两边都去掉。“MER strict” 保留语气词，作为参照。

计算方式：汉字逐字计为一个 token，英文和数字按词计。**MER** 为全部 (S+D+I) 除以参考 token 总数，按全部句子合计，不对逐句比率取平均。**zh-CER / en-WER** 在同一批句子上，两边只保留汉字 token 或只保留英文 token 后分别计算。所以，英文词被识别成汉字时，记为英文的删除加中文的插入。**失控输出**指输出 token 数大于参考的 2 倍再加 10。置信区间用 400 条混说句做配对 bootstrap，以句为单位重采样，2,000 轮，种子 20261027。

已知局限：ASCEND 参考本身有误标，例如多个模型一致输出“同意同意下一步下一步”，参考是“捅一捅一下就下去”。英文复合词切分也不统一，例如 “fin tech” 与 “fintech”。1 个百分点以内的差异不应解读为模型差异。

### 附录 E1：ASCEND 首轮结果（2026-10-27）

#### 混说句（`ascend-mixed-all`，400 条）与单语对照

| 模型 | MER | 95% CI | ΔMER 对基线（95% CI） | zh-CER | en-WER | 纯中文 CER（50 条） | 纯英文 WER（50 条） | 失控 |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **FireRedASR2-AED INT8** | **11.8** | 10.6–13.2 | **−3.7…−1.7** | **9.4** | **26.6** | **7.5** | 18.2 | 0 |
| SenseVoice INT8（基线，auto） | 14.5 | 13.2–15.7 | — | 10.3 | 34.7 | 11.7 | 18.5 | 0 |
| FunASR Nano INT8 + 失控保护（离线模拟，见 CS-Dialogue 一节） | 13.3 | 12.0–14.8 | −2.1…−0.3 | 10.7 | 28.0 | 8.0 | 14.2 | 0 |
| Qwen3-ASR 0.6B INT8 | 14.7 | 13.2–16.2 | −0.8…+1.2 | 12.9 | 33.7 | 8.6 | 17.9 | 0 |
| SenseVoice INT8（固定 zh） | 15.4 | 14.1–16.8 | +0.3…+1.5 | 11.1 | 37.3 | 11.3 | 29.1 | 0 |
| Paraformer zh 2024-03-09 INT8 | 15.8 | 14.3–17.4 | +0.4…+2.2 | 12.4 | 35.8 | 11.3 | 30.1 | 0 |
| FunASR Nano INT8（固定 中文） | 16.5（去失控 12.5） | 11.5–25.2 | −2.5…+10.5 | 10.7 | 44.5 | 8.0 | 14.6 | 1 |
| FunASR Nano INT8（auto，同 App） | 17.3（去失控 13.2） | 12.2–26.1 | −1.9…+11.3 | 10.7 | 46.0（去失控 27.9） | 8.0 | **14.2** | 1 |
| SenseVoice 粤语微调 2025-09-09 | 17.6 | 16.1–19.1 | +2.1…+4.1 | 11.8 | 43.7 | 11.5 | 33.8 | 0 |
| FireRedASR2-CTC INT8 | 19.1 | 17.7–20.5 | +3.6…+5.7 | 10.1 | 55.0 | 11.1 | 37.1 | 0 |
| Whisper large-v3-turbo INT8 | 28.1 | 25.2–31.3 | +10.8…+16.8 | 28.1 | 47.3 | 27.0 | 19.9 | 0 |
| Paraformer 川话微调 2025-10-07 | 36.8 | 34.1–39.8 | +20.0…+24.8 | 30.0 | 99.0 | 14.6 | 100.0 | 0 |
| Dolphin small CTC INT8 | 42.5 | 39.1–46.0 | +24.8…+31.4 | 29.2 | 94.2 | 14.6 | 97.4 | 0 |

单位均为 %。纯中文列为 CER，纯英文列为 WER。Nano 的置信区间很宽，主要来自那 1 条失控句。

分子集看（MER，test / validation）：FireRed AED 10.5 / 13.1，SenseVoice 14.2 / 14.7，Qwen3 13.8 / 15.6，Nano 12.2 / 22.1（失控句在 validation，去掉后为 14.2），Paraformer 13.8 / 17.6。排序在两个子集中基本一致。保留语气词的 strict MER 普遍高约 1 个百分点，排序不变。完整表格见 `runs/scores.md`。

#### 速度、内存与体积（参考值）

| 模型 | RTF（Mac CPU，2 线程） | 首次加载 | 峰值 RSS | 实际使用文件大小 | iPhone 可行性判断 |
| --- | ---: | ---: | ---: | ---: | --- |
| Paraformer zh 2024-03-09 | 0.023 | 1.0 s | 981 MiB | 217 MiB | 可随 App 提供或下载 |
| SenseVoice（基线） | 0.031 | 0.8 s | 1,055 MiB | 229 MiB | 已随 App 提供；iPhone 17 Pro 实测 RTF 约 0.02（见 `asr-throughput-iphone-20261021.json`） |
| Dolphin small | 0.038 | 0.5 s | 988 MiB | 239 MiB | 可行，但准确率不合格 |
| FunASR Nano | 0.170 | 2.9 s | 3,405 MiB | 963 MiB | App 已支持下载（约 1.01 GB）；手机内存与耗时仍待真机测量 |
| Qwen3-ASR 0.6B | 0.197 | 2.2 s | 2,913 MiB | 941 MiB | 与 Nano 同量级；sherpa 已支持，但 App 尚未接入 |
| FireRedASR2-CTC | 0.248 | 1.0 s | 2,091 MiB | 740 MiB | 偏重，准确率不合格 |
| FireRedASR2-AED | 0.342 | 2.4 s | 3,020 MiB | 1,177 MiB | **最重**：下载约 0.84 GB（bz2），解压后 1.18 GB；自回归解码在手机上可能偏慢，须真机测内存峰值和后台耗时 |
| Whisper large-v3-turbo | 0.633 | 1.7 s | 2,985 MiB | 988 MiB | 短句补齐到 30 秒，代价高 |

- RTF 为 500 条的解码总时间除以 1,973 秒音频，不含模型加载，也不含第一条预热解码。测量期间有并发 Xcode 构建，不同模型受到的干扰并不相同。
- 峰值 RSS 是进程级 `ru_maxrss`，其中约 171～179 MiB 是加载模型前已读入的 500 条音频和 Python 运行时。ORT 的 CPU arena 会随输入形状增长，所以这不是手机上的内存门槛。生产 Swift 路径跑 SenseVoice 时的峰值 footprint 为 905 MB，与 Python 的 1,055 MiB 同量级。
- 当前 App 在手机上用 Core ML EP 运行部分子图，Mac CPU 的 RTF 不能换算成 iPhone 耗时。

#### Python 路径与生产 Swift 路径对照

我们用现有 `Tools/SpeechQuality`（生产 `SpeechEngine`：Silero VAD v6.2.3、窗口规划、Core ML 版 SenseVoice、`language=auto`、ITN、2 线程）处理 `ascend-test-mixed` 中按 ID 排序的前 20 条。

- 该工具要求语料总帧数恰好为 57,600,000（FLEURS 的 1 小时），因此另加了一个全零 PCM16 的填充文件。VAD 在其中没有检出语音，没有产生 ASR 窗口，也不参与计分。整个过程没有修改 `Tools/SpeechQuality`。
- 20 条中有 13 条输出与 Python 逐字相同。其余 7 条都是 VAD 裁掉了较长的句首/句尾静音段（5,216～25,888 帧），有 1 条整句被判为无语音。相同的 13 条裁边都较短（≤ 4,320 帧），并在 padding 范围内。这说明 Core ML 与 CPU 的数值差异没有改变识别文本，差异来自 VAD。
- 这 20 条上，Python 的 MER 为 16.4%，生产路径为 19.2%，删除数由 8 增至 16。VAD 位于 ASR 之前，对所有模型的影响相同，不改变模型排序；但真实录音上的绝对错误率会略高于本表。

#### 错误示例

节选自混说子集，每例给出参考文本和模型输出，用于说明错误类型。完整逐句对照见各模型目录下的 `comparisons.jsonl`。

**FireRedASR2-AED**（无标点、英文全大写；主要错误是英文近音词）
1. 参考「我不知道go camping算不算sports」→「WE'RE GOING CAMPING FROM SCIENCE BOX」：中文开头被整句识别成英文。
2. 「facility还可以吧就啊facility也就一般就」→「啊粉色的这些可以吧就啊粉色的这些就一般就」：英文词被识别成发音相近的中文。
3. 「就当初在做exchange student的时候…」→「…EXCHANGE TUESDAY的时候…」。
4. 「…但是我apply是在third years的时候apply」→「…但是我 APPLY是在 THIRTY YEARS OF APPLY」。
5. 「托福toefl toefl score need to be like over one hundred and five」→「TOF TOF TOF SCHOOL NEED TO BE LIKE A BOWL OF HUNDRED AND FIVE」。
6. 正面例：「but when we当我去那的时候…」「小朋友我回想一下when i was in elementary school」「computer language还有problem language的东西」均完全正确或只错 1 词，而其他模型在这些句子上普遍出错。

**SenseVoice（基线）**（英文单词截断或拼错较多）
1. 「…会有更多opportunity」→「…会有更多opportun。」
2. 「就当初在做exchange student…apply to这个program…往哪个方向」→「…exchan student…app to这个 program…往南方向。」
3. 「我觉得Hong Kong这样比较in between就是western还有eastern」→「我觉得hoong k将比较in between，就是wesstern还有ea等」。
4. 「偶尔跟friends传传messages」→「Oregon friendsch messageger.」：整句英文化。
5. 「但是我的supervisor就跟我说也不是supervisor」→「那时我的supervis就跟我说，也不是super白」。
6. 「…就是very special」→「…就 veryryspec。」

**FunASR Nano**（大多数句子很好；少数句子失控或输出外语）
1. 失控：「…是我的parents但parents又又」→「…我的parents，my parents，my parents，…」，"my parents" 重复 120 次，直到 384 token 上限；这一条解码就用了 15～20 秒（Mac CPU）。auto 和固定中文两种设置下都会出现（`temperature=0`，结果确定）。
2. 「呃language那个」→「あ、レングリス、なんか。」：输出了日文。
3. 「mobile payment的」→「姆巴佩门德。」：短英文被音译成汉字。
4. 「所有的homework」→「谁有带红包去？」。
5. 「the first time你就可以enjoy in这个sport」→「At first time you can enjoy this sport.」：整句译成英文。
6. 正面例：「嗯所以你平时会看Olympic games吗过去的几届」、「偶尔跟friends传传messages」几乎完全正确，基线在这两句上明显出错。

**Qwen3-ASR 0.6B**（会把混说句改写成单一语言，属于语义翻译，不是逐字转写）
1. 「所以我们现在开始talk about our research topics」→「So we're now going to talk about our research topics.」
2. 「computer language还有problem language的东西我还是不太懂」→「编程语言，还有编程语言的东西，我还是不太懂。」
3. 「找个地方which is speak in english」→「找一个地方，我去说英语。」
4. 「然后我we will have three groups so」→「然后我们有三组。所以。」
5. 「sandwiches或者是其他东西分给我们吃」→「三文鱼去死，或者是其他的东西，分给我们吃」。

**Whisper large-v3-turbo**：自动检测把 117/400 条混说句判为英文，结果常漏掉中文或把整句译成英文。另有重复循环，例如“非常”重复数十次、“啊 啊 啊…”。60 条输出为繁体。因此只作参考，不进入候选。

### 附录 E2：CS-Dialogue 复测（2026-10-27 晚）

#### 条款与下载

- **用户决定（2026-10-27，由主会话转述的原话）：**「同意条款，下载 CS-Dialogue 重跑评测，尽可能多用cs-diaologue的数据」。用户接受 BAAI/CS-Dialogue 的条款，用于个人非商业评测：CC BY-NC-SA 4.0，仅限学术或非商业研究，不得再分发，受试者要求撤回时须删除。HF 上的 gate 实际没有开启，所以没有经过网页申请表；如需在 BAAI 处登记，须由用户用本人账号提交。
- 用 `uvx --from huggingface_hub hf download` 下载 revision `a84770fcdf14072252373a0227321227eaac7dc7`，只取 `data/short_wav/*`（19 个分卷，共 9,595,542,742 字节）和 `data/index/short_wav/*`。19 个分卷的 SHA256 与 HF LFS oid 全部一致，6 个索引文件的 git blob 哈希与 HF oid 一致。没有下载 `long_wav` 或完整 25 GB 数据集。
- `Tools/ASRCodeSwitchEval/cs_dialogue.py build` 把 19 个分卷当作一个 gzip 流顺序读取，只把 test/dev 索引中列出的 WAV 用我们自己的文件名写出（47 秒），不按成员名解压，也不把归档展开到磁盘。分卷中的 train 音频只经过流，没有写盘。
- **仓库只提交 utterance ID**（`Tools/ASRCodeSwitchEval/csd-eval-ids-v1.json`）。音频、参考文本和逐句输出都只留在 `tmp_agent_output/`。下文不引用任何 CS-Dialogue 原文；错误模式用自己的话描述，示例为虚构并已标明。

#### 划分、筛选与污染风险

| 划分 | 索引条数 | 混说 | 纯中文 | 纯英文 | 说话人 |
| --- | ---: | --- | --- | --- | ---: |
| test | 6,257 | 1,055 条 / 4.81 h | 2,742 / 7.10 h | 1,863 / 4.43 h | 30 |
| dev | 6,186 | 1,157 / 5.58 h | 2,545 / 7.72 h | 1,746 / 4.61 h | 30 |

- 按转写分类：去掉 `<FIL/>`、`<SPK/>`、`<NON/>`、`<NPS/>` 标签和语气词后，同时含汉字和拉丁字母的为混说，只含一种的为单语。两个划分中共有 1,335 条只剩标签或语气词，已排除。test、dev 与 train（140 人）三者说话人互不重叠。
- **只保留不超过 20 秒的句子**，test 中 325 条、dev 中 376 条混说句因此被排除。原因有两点：一是 App 送给 ASR 的窗口最长 20 秒；二是实测 FunASR Nano 的 KV 上下文只有 512 token，对一条 60 秒的句子，sherpa 会截断音频占位符并输出空文本。同一条句子让 Qwen3-ASR 的 RSS 达到 5.8 GB。
- 评测集 `corpus-csd-eval-v1`：test-mixed 全部 730 条（2.00 h），dev-mixed 全部 781 条（2.39 h），另按固定种子从每个划分各抽 300 条纯中文和 300 条纯英文作为对照（0.51～0.56 h）。规范化、MER 定义与 bootstrap 方法均与 ASCEND 相同（`momo-cs-mer-v1`）。CS-Dialogue 的参考文本中没有阿拉伯数字，`*` 一类的不清晰标记按标点处理。
- **污染风险：** CS-Dialogue 的论文发布于 2025-02，HF 数据集于 2025-07-22 公开。Fun-ASR-Nano-2512（HF 2025-12-15）、Qwen3-ASR（2026-01-28）和 FireRedASR2（2026-02-12）都在此之后发布，训练数据没有完整公开，不能排除它们见过 train，甚至 test/dev。SenseVoice（2024-07）和 Paraformer（2024-02/03）早于数据集发布，不存在这一问题。本评测没有使用 train，但这三个新模型在 CS-Dialogue 上的优势应视为上限。（ASCEND 自 2021 年起公开，所有模型都可能见过它。）

#### 运行情况

- 5 个模型（SenseVoice、Paraformer、FireRed AED、Nano、Qwen3）以多进程并行运行，每进程 2 线程，均为 CPU。采样到的合计 RSS 最高约 10.8 GB，单进程最高约 3.5 GB（Qwen3）。
- **速度数据无参考价值：** 本机当时使用电池并开启低电量模式，17:00～23:00 之间进入睡眠 57 次。并行时 load average 为 15～20，FireRed AED 的单进程表观 RTF 约 0.9。因此本节不报告 RTF，速度与内存以 ASCEND 一节为准。
- 由于睡眠，重模型最初 5 小时只完成了约四分之一。之后在机器清醒时用 `--resume` 续跑，并把 FireRed 的剩余句子按 uid 分块并行处理。greedy 解码结果是确定的，分块不改变输出。每个模型只计入完整跑完的子集，所以同一张表里各模型的句子完全相同。
- Nano 失控保护为离线模拟，由 `Tools/ASRCodeSwitchEval/nano_guard.py` 实现：（1）按时长截断，最多保留 ⌈10 token/s × 时长⌉ + 16 个 Qwen3 token。greedy 解码下，这与把 `max_new_tokens` 设为同一上限得到的前缀相同。（2）同一短语连续出现 4 次及以上时，压缩为 2 次。之所以只能离线模拟，是因为 sherpa-onnx 1.13.8 的 `max_new_tokens` 在创建识别器时就已固定，Python 中调用 `set_config` 实测不生效。**App 目前没有这层保护。**

#### 结果：test（主结果，混说 730 条 + 单语对照各 300 条）

| 模型 | MER | 95% CI | ΔMER 对基线（95% CI） | zh-CER | en-WER | 失控 | 纯中文 CER | 纯英文 WER |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **FireRedASR2-AED INT8** | **5.6** | 5.1–6.2 | **−3.1…−2.1** | **4.3** | **16.9** | 0 | **2.4** | 11.5 |
| FunASR Nano INT8 + 失控保护（模拟） | 6.6 | 5.8–7.5 | −2.2…−0.8 | 5.5 | 18.8 | 0 | 2.4 | 11.5 |
| Paraformer zh 2024-03-09 INT8 | 7.3 | 6.6–8.0 | −1.4…−0.4 | 4.9 | 23.5 | 0 | 2.5 | 16.9 |
| SenseVoice INT8（基线，auto） | 8.2 | 7.5–8.9 | — | 5.7 | 26.8 | 0 | 3.4 | **10.9** |
| FunASR Nano INT8（同 App） | 8.3（去失控 6.4） | 6.0–12.3 | −2.1…+4.0 | 5.6 | 28.4 | 2 | 2.4 | 11.4 |
| Qwen3-ASR 0.6B INT8 | 11.8（去失控 9.4） | 8.9–15.8 | +0.8…+7.7 | 9.1 | 39.8 | 3 | 2.6 | 11.0 |

单位均为 %。纯中文、纯英文两列在 test 的单语对照上计算。保护规则在单语对照中改动了 2 条正常输出（都是英文中真实出现的多次重复），使纯英文 WER 从 11.4% 变为 11.5%。

#### 结果：dev（混说 781 条）

| 模型 | MER | 95% CI | ΔMER 对基线（95% CI） | zh-CER | en-WER | 失控 |
| --- | ---: | --- | --- | ---: | ---: | ---: |
| **FireRedASR2-AED INT8** | **4.5** | 4.1–5.0 | **−2.3…−1.5** | **3.3** | **14.9** | 0 |
| FunASR Nano INT8 + 失控保护（模拟） | 5.6 | 4.8–6.7 | −1.6…+0.2 | 4.8 | 15.3 | 1 |
| Paraformer zh 2024-03-09 INT8 | 6.0 | 5.5–6.6 | −0.8…+0.1 | 4.2 | 19.9 | 0 |
| SenseVoice INT8（基线，auto） | 6.4 | 5.9–6.9 | — | 4.2 | 22.0 | 0 |
| FunASR Nano INT8（同 App） | 6.8（去失控 5.3） | 5.0–9.7 | −1.4…+3.4 | 5.0 | 21.7 | 2 |
| Qwen3-ASR 0.6B INT8 | 8.8（去失控 8.0） | 7.2–10.9 | +0.8…+4.5 | 7.6 | 27.6 | 1 |

dev 的单语对照只有 SenseVoice 和 Paraformer 跑完（纯中文 CER 2.7% / 2.4%，纯英文 WER 10.9% / 15.5%）；重模型在 dev 上只跑了混说句。test 与 dev 合并的 1,511 条混说句（`csd-mixed-all`）上：FireRed AED 5.0%（−2.5…−1.9），Nano 加保护 6.0%（−1.7…−0.5），Paraformer 6.6%（−0.9…−0.3），SenseVoice 7.2%，Nano 原样 7.5%（失控 4 条），Qwen3 10.2%（+1.3…+5.1，失控 4 条）。dev 上有 1 条 Nano 输出在加保护后仍被判为失控：时长上限允许的长度仍超过参考的 2 倍再加 10，但重复已被压缩。

#### 与 ASCEND 的对比

- **排序一致：** FireRed AED 第一，Nano 加保护后第二。FireRed 在所有子集上都显著优于基线；Nano 加保护在 dev 上的差异不显著，其余子集显著。Qwen3 在两个数据集上都没有优于基线，在 CS-Dialogue 上更差，因为翻译式改写之外还有 3 条失控输出。
- **Paraformer 与 SenseVoice 的位置互换：** Paraformer 在 CS-Dialogue 混说上略好（test −0.9 个百分点），在 ASCEND 上略差（+1.3），纯英文在两个数据集上都明显更差（CS-Dialogue 16.9% 对 10.9%）。总体与基线相当，不值得替换。
- CS-Dialogue 的绝对错误率约为 ASCEND 的一半。前者是录音条件较好的普通话—英语对话，说话人英语水平较高（雅思 ≥ 6 或专四）；后者是香港校园闲聊，噪声和口音更重。用户的真实录音大概率介于两者之间。
- Nano 失控出现在两个数据集上：ASCEND 1/400，CS-Dialogue 混说 4/1,511（test 2，dev 2）。Qwen3 在 CS-Dialogue 上也是 4/1,511。可见失控不是个别现象，任何 LLM 类 ASR 上线前都必须加长度或重复保护。

#### 错误模式（自述，示例为虚构）

- **SenseVoice：** 以英语为主的句子被判为英语后，中文专名（公司、应用、人名）会被写成拼音或英文。CS-Dialogue 的参考文本用汉字，因此计为错误。另有一些夹在英文中的短中文片段被整段漏掉，表现为删除数高。虚构示例：参考「我们用微信 pay」，输出 “we use weixin pay”。
- **FireRed AED：** 错误主要是英文近音词；输出没有标点，英文全大写，与 ASCEND 上相同。
- **Nano：** 两条失控都是同一个短词组循环到上限，一条为英文虚词，一条为两字中文。其余错误多为漏掉句中短英文。
- **Qwen3：** 除了把英文意译成中文、或把整句改写成英文，还有 3 条输出远长于语音内容：2 条在重复短句，1 条在原句之后续写出不存在的内容。

### 附录 E3：App 新 Nano 运行时复测（2026-10-29）

#### App 侧的变化

Miri-Labs main `b68c6250`（v0.0.1）不再用 sherpa-onnx 内置的 `funasr_nano` 解码器，改用自带的原生运行时 `Vendor/SherpaOnnx/Sources/MoMoSherpaBridge/FunASRNano.cpp`（`MoMoCreateFunASRNanoRuntime` / `MoMoTranscribeFunASRNano`），由 `MoMoSpeech/Engines/Sherpa/SherpaRuntime.swift` 调用，指纹标签为 `funasr-nano-ort-cpu-naud-v2`。理由见 `docs/implementation/funasr-nano-and-diarization-20261029.md`。与上文离线评测相关的差异：

- 只把编码器输出的前 `n_aud` 个低帧率位置送入 Qwen3（约为原来的 1/8）；LFR 改为居中填充，与 FunASR 的 `apply_lfr` 一致。
- 解码时加重复惩罚 1.12（128 token 窗口，数字和分句标点除外）和 no-repeat 5-gram；`max_new_tokens` 按时长取 ⌈9 × 秒数⌉ + 24，限制在 32～192 之间；删除 `/sil` 等特殊标记。
- 只走 ORT CPU，不用 Core ML EP。提示词不变：语言为自动时为「语音转写：」，ITN 开。
- 归档识别时，Nano 只接收窗口的 core 音频，不含两侧上下文。

模型文件不变：`models/funasr-nano-int8-20251230` 的 6 个文件与 `funasr-nano-onnx-v1.json` 的大小和 SHA256 逐一一致。

#### 运行方式

- 新增 `Tools/ASRCodeSwitchEval/NanoAppRuntime/`：一个 macOS SwiftPM 可执行程序，按路径依赖 `Packages/MoMoAgentKit`，用 `@testable import MoMoSpeech` 直接调用 App 的 `SherpaRuntime`，没有重新实现任何识别逻辑。配置与 iPhone App 相同：`SpeechConfiguration()` 默认值（语言自动、ITN 开、2 线程）、`DownloadableSpeechModel.funASRNano()` 清单校验、加载后 warm-up。每条语句整句作为窗口 core 输入（都不超过 20 秒），并照 `SpeechEngine.recognizeArchive` 在 `continuousArchive` 下的做法，去掉首尾的精确零值采样。不包括说话人分离后按 turn 重新解码的步骤。音频用 `AVAudioFile` 读成 Float32，与 App 读取归档音频的方式相同。
- 输出格式与 `models.py` 相同（`hypotheses.jsonl` + `run.json`），用原 `score.py` 评分，参数不变（`momo-cs-mer-v1`，bootstrap 2,000 轮，种子 20261027，CS-Dialogue 加 `--present-only`）。旧的 SenseVoice、Nano、Nano 加保护三行在新目录中重算，数值与上文完全一致。
- Release 构建（`-enable-testing`）。sherpa 二进制按 `Native/SpeechVendor/runtime-manifest.json` 校验后放在已忽略的 `Vendor/SherpaOnnx/Binaries/`。
- ASCEND 500 条为单进程运行，用于测速；CS-Dialogue 2,111 条（test-mixed 730、test-zh 300、test-en 300、dev-mixed 781）按序号分 4 片并行，可用 `--resume` 续跑，全程套 `caffeinate -dims`。所有语句都完成，0 条报错。
- 先用 40 条做了检查（ASCEND test-mixed 前 20 条；CS-Dialogue 上旧版失控的 4 条，加各子集若干条）。输出都是正常文本；ASCEND 20 条中有 10 条与旧输出逐字相同；旧版的 4 条 CS-Dialogue 失控句都不再重复。

#### 结果

| 模型 | 体积 | ASCEND 混说 MER（400） | CSD test 混说 MER（730） | CSD dev 混说 MER（781） |
| --- | ---: | --- | --- | --- |
| **FunASR Nano INT8（App 新运行时）** | 963 MiB | **13.2**（Δ −2.2…−0.3，失控 0） | **6.7**（Δ −1.9…−0.9，失控 0） | **5.1**（Δ −1.7…−0.9，失控 0） |
| FunASR Nano INT8 + 失控保护（离线模拟） | 963 MiB | 13.3（−2.1…−0.3，0） | 6.6（−2.2…−0.8，0） | 5.6（−1.6…+0.2，1） |
| FunASR Nano INT8（sherpa 内置解码，旧 App） | 963 MiB | 17.3（−1.9…+11.3，1） | 8.3（−2.1…+4.0，2） | 6.8（−1.4…+3.4，2） |
| SenseVoice INT8（基线） | 229 MiB | 14.5 | 8.2 | 6.4 |

单位均为 %，Δ 为相对基线的 MER 差值的配对 bootstrap 95% 区间。补充指标：

| 模型 | ASCEND zh-CER / en-WER | ASCEND 纯中文 CER / 纯英文 WER（各 50） | CSD test zh-CER / en-WER | CSD test 纯中文 CER / 纯英文 WER（各 300） | CSD dev zh-CER / en-WER | CSD 合并 1,511 条 MER |
| --- | --- | --- | --- | --- | --- | --- |
| Nano 新运行时 | 11.2 / 28.1 | 8.4 / 15.2 | 5.6 / 18.3 | 3.1 / 11.5 | 4.3 / 13.8 | 5.9（−1.7…−1.0） |
| Nano + 保护（模拟） | 10.7 / 28.0 | 8.0 / 14.2 | 5.5 / 18.8 | 2.4 / 11.5 | 4.8 / 15.3 | 6.0（−1.7…−0.5） |
| Nano 旧版 | 10.7 / 46.0 | 8.0 / 14.2 | 5.6 / 28.4 | 2.4 / 11.4 | 5.0 / 21.7 | 7.5（−1.4…+2.5） |
| SenseVoice | 10.3 / 34.7 | 11.7 / 18.5 | 5.7 / 26.8 | 3.4 / 10.9 | 4.2 / 22.0 | 7.2 |

- **失控已消除。** 在全部 2,611 条（含单语对照）上，新运行时没有一条输出满足失控定义。旧版的 5 条失控句（ASCEND `validation-00675`，CS-Dialogue `ZH-CN_U1019_S0_114`、`ZH-CN_U1069_S0_112`、`ZH-CN_U0023_S0_479`、`ZH-CN_U0081_S0_123`）都恢复为正常长度；其中 3 条完全正确或只错 1 个 token，`ZH-CN_U1019_S0_114` 只输出了参考的约四分之一。
- **与离线模拟的保护相当，而且置信区间收窄。** 三个混说集都显著优于基线，dev 上也显著，这一点不同于旧版加模拟保护。
- **不失控的句子上大致持平，略有得失。** 只看旧版不失控的句子，MER 旧/新为：ASCEND 13.2 / 13.2，CSD test 6.4 / 6.7，dev 5.3 / 5.1。新运行时的删除错误更多（CSD 混说 D 由 632 增至 767），插入大幅减少（1,105 降至 374）。CS-Dialogue 纯中文对照的 CER 由 2.4% 升到 3.1%，删除与替换都有增加。删除增加 ≥ 3 个 token 的 34 条句子中，多数漏在句中，不在句尾，看起来不是 `max_new_tokens` 截断。需要在真实录音上留意漏词。
- 日文或韩文输出由 8 条降至 3 条，没有空输出。
- **速度与内存（ASCEND 500 条，单进程，2 线程）：** RTF 0.114（解码 224 s / 音频 1,973 s；旧版 Python 为 0.170），加载 2.7 s，峰值 RSS 2,383 MiB（`ru_maxrss`，`/usr/bin/time -l` 的 peak footprint 为 2.47 GB；旧版为 3,405 MiB）。测速时本机使用电池并开启低电量模式，1 分钟 load average 约 1.6～2.2；旧版测速时有并发 Xcode 构建，两者只能粗略比较。CS-Dialogue 4 片并行时合计 RSS 最高约 7.2 GB，每片约 1.8 GB。期间另一项评测也在运行，load average 最高约 13，所以分片 RTF（约 0.23）不作参考。

### 附录 E4：扩展评测：新模型与 FireRedASR2-AED 量化（2026-10-29）

本节加入 X-ASR、Apple 系统识别、Qwen3-ASR 1.7B、FireRedASR2-AED 的 4 bit 变体与 FireRedASR2-LLM。语料、`momo-cs-mer-v1` 规范化、失控定义与 bootstrap（2,000 轮，种子 20261027）均与上文相同，评分用未改动的 `score.py`。

#### 运行条件

- **协议：** 每个模型或变体都跑 ASCEND 全部 500 条（混说 400 条为主，另有纯中文、纯英文对照各 50 条），以及 CS-Dialogue 2,111 条（test-mixed 730、test-zh 300、test-en 300、dev-mixed 781）。Apple `en-US` 只跑混说集，作参照。
- **评分：** 先把原有各模型的 `hypotheses.jsonl` 与新运行复制到 `scores-ext/` 下重新计分，两个数据集都加 `--present-only`；原有各行与上文数值一致。默认基线仍为 SenseVoice；另用 `--baseline fireredasr2-aed-int8-20260226` 再算一遍，得到相对 FireRed INT8 的配对差值（`scores-ext/*-vsfr/`）。量化变体只与 INT8 原版比较（`scores-ext/*-firered/`）。
- **执行：** 每个模型一个进程，按 1→5 的顺序逐个运行，脚本可 `--resume`，全程套 `caffeinate -dims`。sherpa 模型仍为 CPU、2 线程、greedy。RTF 为解码总时间除以音频时长，不含加载和首条预热。
- **机器状态：** 全程使用电池，并开启低电量模式（`pmset -g` 显示 `lowpowermode 1`）。14:21 之前，上节的 Nano 分片运行与本轮同时进行，load average 约 13；X-ASR 流式 0.66 s 版的 ASCEND 段就跑在这段时间，所以该段的 RTF 偏高、不作参考。此后本机只运行本轮任务。速度数字可在本节内部比较，和 10-27 的数字只能粗略对照。
- **内存：** sherpa 进程报告 `ru_maxrss`。Apple 识别在系统进程里完成，MPS 和 Core ML 的显存也不完全计入 RSS，所以这几项另报 phys footprint 或守护进程 RSS，见各小节。

#### 1. X-ASR-zh-en（流式 Zipformer，2026-06）

**来源：** [Gilgamesh-J/X-ASR](https://github.com/Gilgamesh-J/X-ASR)（上海交大、上海创智学院、复旦、华科，Apache-2.0）。README 称约 100 万小时开源和自采数据训练，模型为 Zipformer transducer，约 0.16B 参数，支持标点和大小写，技术报告尚未发布。sherpa-onnx 的 `asr-models` release（2026-06-29 上传）把同一个 checkpoint 导出为 160 / 480 / 960 / 1920 ms 四种流式块，另有非流式版本，各自有带标点与不带标点、fp32 与 INT8 两种。**它没有不同的模型尺寸，只有块大小的差别。** 本文选 **480 ms、带标点、INT8**：sherpa-onnx 自己的端侧示例（Android QNN）用的就是 480 ms，带标点的版本与 App 需要的输出一致。App 识别的是 VAD 切好的完整窗口，用不上流式的低延迟，所以也跑了同一 checkpoint 的非流式 INT8 导出作为离线参照，成本很低。

| 运行名 | 发布文件 | 校验 | 实际使用文件 | 许可 |
| --- | --- | --- | ---: | --- |
| `x-asr-streaming-480ms-punct-int8-20260605` | `sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05.tar.bz2` | GitHub digest `fa5f63d6…` | 161 MiB（encoder INT8 148 + decoder fp32 10.8 + joiner INT8 2.5） | Apache-2.0 |
| `x-asr-offline-punct-int8-20260603` | `sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03.tar.bz2` | GitHub digest `5d02c36d…` | 167 MiB（encoder INT8 154 + decoder fp32 10.8 + joiner INT8 2.5） | Apache-2.0 |

非流式归档中的 encoder（161,015,713 字节）与 HF 镜像 `csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03` @ `ce812cc0` 上的文件（161,744,450 字节）不同，是另一次导出；joiner 两边一致。本文以 GitHub release digest 为准。

**2026-10-30 补测 HF 镜像版：** App 的安装器只能逐个下载文件，因此又按文件下载了上述 HF 镜像 @ `ce812cc0`（运行名 `x-asr-offline-punct-int8-20260603-hf`，在 `models.py` 中登记为本地目录）。逐文件 SHA256：encoder `fe0198b52626f2a1012ebb6d6a7259c5137c4c964f3a524135e353f4687b5d14`（161,744,450 字节），decoder `a9fe7c320337e6f510809c028a8accf074d45f42aab852e2d29830babc41a3f9`（11,309,084 字节，与归档中的 `72f47405…` 不同），joiner `aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3`、`bpe.model` `f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f`、`tokens.txt` `b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c`（这三个与归档逐字节相同），均与 HF LFS oid 一致。在 ASCEND 500 条和 CS-Dialogue 2,111 条上重跑，2,611 条输出与归档版本逐字相同，MER 与配对差值完全一致（+0.0…+0.0）。这次重跑的 RTF 为 0.012 / 0.010，低于归档版本的 0.020，是机器状态不同（已接电源、无其他任务），不是模型差异。

**流式解码方式与尾部静音：** 整句送入 `OnlineRecognizer`，关闭端点检测，greedy，末尾补静音后调用 `input_finished()`。sherpa 只解码完整的块，所以尾部静音必须盖住一个块再加上模型的输出延迟。最初沿用 sherpa 示例里的 0.66 s，结果在 ASCEND 上句末常丢 1～2 个词，纯中文对照的删除数为 49 个 token，而非流式版只有 8 个。在 ASCEND 两个单语对照（共 100 条）上扫描尾部静音（纯中文 CER / 纯英文 WER）：0.66 s 为 18.6 / 30.5，1 s 为 12.8 / 24.5，2 s 为 10.0 / 22.5，3 s 为 10.0 / 22.2。因此正式结果用 2 s；0.66 s 的完整运行保留为 `-tail066`，只用来说明这一点。这是评测接入方式造成的，不是模型本身的问题。App 若接流式模型，也要在窗口末尾补足一个块以上的静音再结束。CS-Dialogue 的句子本身多以静音结尾，0.66 s 与 2 s 的结果几乎相同（test 7.5 / 7.5）。

| 模型 | ASCEND 混说 MER（Δ 对 SenseVoice / 对 FireRed INT8） | CSD test 混说 | CSD dev 混说 | zh-CER / en-WER（ASCEND；CSD test） | 纯中文 CER / 纯英文 WER（ASCEND；CSD test） | 失控 | RTF（ASCEND / CSD） | 峰值 RSS |
| --- | --- | --- | --- | --- | --- | ---: | --- | --- |
| **X-ASR 非流式 INT8** | **12.2**（−3.1…−1.4 / −0.6…+1.3） | **5.9**（−2.7…−1.8 / −0.1…+0.7） | **4.7**（−2.1…−1.2 / −0.2…+0.7） | 10.0 / 25.4；4.7 / 16.4 | 9.3 / 17.2；2.9 / 10.4 | 0 | **0.020 / 0.020** | 713 / 1,013 MiB |
| X-ASR 流式 480 ms INT8（尾部 2 s） | 14.0（−1.6…+0.8 / +1.1…+3.5） | 7.5（−1.2…−0.1 / +1.4…+2.5） | 6.2（−0.8…+0.4 / +1.1…+2.3） | 11.4 / 30.1；6.3 / 19.5 | 10.0 / 22.5；4.0 / 13.7 | 0 | 0.071 / 0.054 | 491 / 497 MiB |
| X-ASR 流式（尾部 0.66 s，仅说明用） | 16.8（+1.3…+3.6 / +3.9…+6.3） | 7.5 | 6.3 | 13.9 / 33.9；6.3 / 19.6 | 18.6 / 30.5；4.1 / 14.2 | 0 | — | — |
| FireRedASR2-AED INT8（对照） | 11.8 | 5.6 | 4.5 | 9.4 / 26.6；4.3 / 16.9 | 7.5 / 18.2；2.4 / 11.5 | 0 | 0.342 / — | 3,020 MiB |
| SenseVoice INT8（基线） | 14.5 | 8.2 | 6.4 | 10.3 / 34.7；5.7 / 26.8 | 11.7 / 18.5；3.4 / 10.9 | 0 | 0.031 / — | 1,055 MiB |

单位均为 %。括号内为配对 bootstrap 的 MER 差值 95% 区间。流式版的 RTF 含末尾 2 s 静音的计算；真正流式使用时，这部分只在每个窗口结束时出现一次。

- **非流式 X-ASR 与 FireRed AED INT8 处在同一档：** 三个混说集上与 FireRed 的差值区间都包含 0，而体积约为其 1/7（167 对 1,177 MiB），RTF 约为其 1/17（0.020 对 0.342），峰值 RSS 约 0.7～1.0 GB。纯英文对照还略好于 FireRed（ASCEND 17.2 对 18.2，CSD 10.4 对 11.5）。输出带标点，英文有大小写，没有失控，也没有阿拉伯数字。
- **流式 480 ms 明显差一档：** 在 CS-Dialogue test 上仍显著优于 SenseVoice，ASCEND 与 dev 上与 SenseVoice 持平，三处都显著差于 FireRed 和非流式版。差距来自块内只能看到有限的右侧上下文。
- **错误类型（ASCEND）：** X-ASR 的典型错误是短英文词被写成同音汉字，例如 “ocr” 写成「欧西亚」，“latte” 写成「辣脆」，以及偶尔整段漏掉混说句中的英文（「computer language还有problem language的东西」中漏掉了后一半），FireRed 在这些句子上正确。反过来，FireRed 把整句判成英文或写成同音汉字的几句（「我不知道go camping算不算sports」、「facility还可以吧」、「是不能用这些mobile payment」），X-ASR 基本正确。
- **污染风险：** X-ASR 于 2026-06 发布，在 CS-Dialogue 公开之后，训练数据未列明，与 FireRed、Nano、Qwen3 一样，它在 CS-Dialogue 上的成绩应视为上限。

#### 2. Apple 系统识别（macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`）

**工具：** 新增 `Tools/ASRCodeSwitchEval/AppleSpeech/`，是一个 SwiftPM 可执行程序 `AppleSpeechEval`，部署目标 macOS 26。子命令 `locales` 列出语言与资源状态，`install` 通过 `AssetInventory.assetInstallationRequest` 安装资源，`run` 逐条转写，写出与 `models.py` 相同的 `hypotheses.jsonl` 和 `run.json`，支持 `--resume`。每条语句新建 `SpeechTranscriber(locale:, preset: .transcription)` 和 `SpeechAnalyzer`（`modelRetention: .processLifetime`，模型在语句之间保持加载），用 `analyzeSequence(from: AVAudioFile)` 读取 WAV，`finalizeAndFinish` 后把全部 final 结果用空格拼接。`SpeechTranscriber` 只在本机推理，没有服务器模式；网络只用于下载语言资源。

**权限：** 没有出现系统授权弹窗。用文件输入调用 `SpeechTranscriber` 不需要麦克风权限，也没有要求语音识别授权，用户无需任何操作。

**语言与资源：**

- `SpeechTranscriber.supportedLocales` 共 30 个，包括 `zh_CN`、`zh_TW`、`zh_HK`、`yue_CN`、`en_US` 等。没有中英混合的 locale，每个模块只能指定一种语言。
- 开始时 `installedLocales` 中已有 `zh_CN`、`zh_TW`，但 `AssetInventory.status` 对 `zh_CN` 报告为 `supported`（未安装）。`install --locale zh-CN` 0.5 秒即完成，没有下载（资源已在磁盘上，只是为本程序登记）；`en-US` 实际下载，用时 13 秒。
- API 不提供资源体积。下面是 `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/` 中的实际占用：`com.apple.speech.asr.transcription.cmn`（版本 3100.44005.81707）363 MiB，`com.apple.speech.asr.transcription.en`（同一版本）392 MiB，两者共用的 `asr.language.identification` 16 MiB。资源由系统管理、各 App 共用，不进 App 包。

| 设置 | ASCEND 混说 MER（Δ 对 SenseVoice） | CSD test 混说 | CSD dev 混说 | zh-CER / en-WER（ASCEND；CSD test） | 纯中文 CER / 纯英文 WER（ASCEND；CSD test） | 失控 | RTF（ASCEND / CSD） |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| `zh-CN`（主结果） | 19.7（+4.0…+6.5） | 10.9（+2.1…+3.3） | 9.4（+2.4…+3.4） | 10.2 / 57.7；4.8 / 44.1 | 11.1 / 45.4；3.0 / 39.3 | 0 | 0.028 / 0.018 |
| `en-US`（只跑混说集，参照） | 84.6 | 86.3 | 86.3 | 100 / 178.5；100 / 149.9 | — | 0 | 0.029 / 0.019 |

单位均为 %。相对 FireRed INT8，`zh-CN` 在三个混说集上分别差 +6.5…+9.3、+4.7…+5.9、+4.3…+5.4 个百分点。

- **中文好，英文差。** `zh-CN` 的中文部分与 SenseVoice 相当或略好（ASCEND zh-CER 10.2 对 10.3，CS-Dialogue test 4.8 对 5.7；纯中文对照 11.1 对 11.7、3.0 对 3.4），但句中英文的 WER 达 44～58%，纯英文对照也有 39～45%。英文按读音拼写，经常拼错或粘连，例如 “swimming” 写成 “sweming”、“very little money” 写成 “Fery litle mony”、“environment” 写成 “evimet”。混说 MER 在三个集上都显著差于 SenseVoice。
- `en-US` 完全丢掉中文，并把中文音译成英文单词，因此只作参照，也不适合与 `zh-CN` 组合使用。
- 输出带标点，部分数字为阿拉伯数字（ASCEND 11 条，CS-Dialogue 混说 52 条），已由规范化处理；没有失控。
- **速度与内存：** RTF 为 0.028（ASCEND）和 0.018（CS-Dialogue），是本文最快的。推理不在本进程内：客户端进程峰值 RSS 只有 21～24 MiB；每 5 秒采样一次，XPC 服务 `localspeechrecognition` 最高 185 MiB（zh）/ 139 MiB（en），同时 `aned`（神经网络引擎守护进程）在工作。神经网络引擎上的内存不计入任何进程的 RSS，所以这一项不能与其他模型直接比较。
- **结论：** 不适合作为中英混说的主识别模型。它的优点是零下载体积（系统资源）、极快和省电，可以考虑作为纯中文场景或模型尚未下载时的兜底。

#### 3. Qwen3-ASR 1.7B（官方 `qwen-asr` 包）

**来源与运行方式：** 官方权重 `Qwen/Qwen3-ASR-1.7B` @ `7278e1e7`（Apache-2.0，两个 safetensors 分片的 SHA256 `a4cd1f1a…` 和 `6e0b9d9e…` 与 HF LFS oid 一致，共 4,485 MiB，bf16）。推理用官方包 `qwen-asr==0.0.6`（PyPI wheel SHA256 `b9c55a38…`，依赖 `transformers==4.57.6`）和 `torch==2.9.1`，transformers 后端，`device_map="mps"`、bf16，batch 1，`max_new_tokens=512`，greedy（`generation_config.json` 为 `do_sample=false`），语言为自动（`language=None`），不加上下文提示，只转写。脚本为新增的 `Tools/ASRCodeSwitchEval/qwen3_asr_hf.py`，每条记录包里解析后的文本，同时保留模型原始输出 `raw`。官方包在解析时会调用 `detect_and_fix_repetitions` 压缩重复，评分用的是包的输出。

先做了 20 条试跑：bf16 的 RTF 为 0.66，fp16 为 0.59，且 fp16 改变了 2 条输出，因此正式运行仍用官方推荐的 bf16。正式运行的 RTF 低于试跑，因为 MPS 会按输入形状编译，同样长度的句子越多，可复用的编译结果越多。

| 模型 | ASCEND 混说 MER（Δ 对 SenseVoice / 对 FireRed INT8） | CSD test 混说 | CSD dev 混说 | CSD 合并 1,511 条 | zh-CER / en-WER（ASCEND；CSD test） | 纯中文 CER / 纯英文 WER（ASCEND；CSD test） | 失控 |
| --- | --- | --- | --- | --- | --- | --- | ---: |
| **Qwen3-ASR 1.7B（官方包，MPS bf16）** | **12.8**（−2.9…−0.4 / −0.3…+2.2） | 8.1，去失控 6.8（−2.1…+3.2 / +0.5…+5.8） | **5.4**（−1.7…−0.2 / +0.2…+1.7） | 6.7（−1.6…+1.0 / +0.5…+3.3） | 11.6 / 27.3；6.6 / 28.3 | 8.6 / 14.6；2.4 / 8.6 | 0 / 1 |
| Qwen3-ASR 0.6B INT8（sherpa，对照） | 14.7 | 11.8 | 8.8 | 10.2 | 12.9 / 33.7；9.1 / 39.8 | 8.6 / 17.9；2.6 / 11.0 | 0 / 4 |

单位均为 %。失控列为 ASCEND / CS-Dialogue 混说。

- **比 0.6B 明显好，但没有超过 FireRed。** ASCEND 上显著优于 SenseVoice，与 FireRed 差异不显著；CS-Dialogue dev 上显著优于 SenseVoice，但显著差于 FireRed；test 上被 1 条失控拉高，与 SenseVoice 差异不显著。纯英文对照最好：ASCEND WER 14.6%，CS-Dialogue 8.6%，全表最低。
- **翻译式改写仍在。** 1.7B 自动判定的语种中，ASCEND 有 163 条、CS-Dialogue 有 804 条判为英语（含纯英文对照）。用同一条粗略规则统计，即混说句的参考中有 4 个以上汉字，而输出中只剩不到 20%，同时英文没有减少，这样的“整句改写成英文”在 ASCEND 400 条中有 10 条，CS-Dialogue 1,511 条中有 59 条。0.6B 分别为 2 和 58 条，FireRed 为 1 和 11 条，SenseVoice 为 1 和 24 条。ASCEND 中的例子：「所以我们现在开始talk about our research topics」→ “So we now start to talk about our research topics.”；「the first time你就可以enjoy in这个sport」→ “The first time, you can enjoy this sport.”。另一类是把短英文词写成同音汉字，例如 “Alipay” 写成「阿里配」、“koala bear” 写成「可阿拉贝尔」、“mobile payment” 写成「母巴培们」。
- **失控 1 条：** CS-Dialogue test 中一条 19.7 秒的句子，参考 59 个 token，输出 278 个 token，只用了 7 种 token，是一个重复循环，解码耗时 35 秒。官方包的 `detect_and_fix_repetitions` 只删去了 26 个字符，没有截住。0.6B 在这一句上没有失控。全部 2,611 条中，这一修复只改动了这 1 条输出。
- **速度与内存：** RTF 0.326（ASCEND）、0.209（CS-Dialogue），加载 2.2 s。`ru_maxrss` 为 2.9 / 5.1 GB，但 MPS 的显存不完全计入 RSS。用 `proc_pid_rusage` 读取的 lifetime 最大 phys footprint 在 ASCEND 上为 8.6 GB，在 CS-Dialogue 上达到 20.4 GB（MPS 缓存分配器在长句上不断扩张；结束时 `torch.mps.driver_allocated_memory()` 为 9.0 GB）。权重为 4.5 GB，未量化；要放进手机，至少需要 4 bit 量化，并在 App 里重写推理。
- **结论：** ASCEND 上与 Nano 新运行时相当（12.8 对 13.2），CS-Dialogue 上不如它（test 8.1 对 6.7，dev 5.4 对 5.1），也不如 FireRed；体积和内存都远大于 FireRed INT8，还保留翻译式改写和失控的风险。不建议进入真机测试。

#### 4. FireRedASR2-AED 量化变体

**起点与来源：** 基线是已发布的 `sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26`（1,177 MiB）。fp32 版来自 sherpa-onnx 上传账号的 HF 仓库 `csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-2026-02-26` @ `54e7d658`：`encoder.onnx` 加外部权重 `encoder.weights`（3,103 MB）和 `decoder.onnx`（1,584 MB）。这些文件与 ModelScope `csukuangfj/FireRedASR2-AED-onnx` 中 `aed/` 目录下的 fp32 文件逐一同哈希（`encoder.weights` `6774fd9b…`、`decoder.onnx` `c67df92a…`）；同一目录里的 `encoder.int8.onnx`（`54048d66…`）和 `decoder.int8.onnx`（`b840ce71…`）正是已发布的 INT8 文件，可见两者来自同一次导出。INT8 版是 ONNX Runtime 动态量化：`MatMulInteger` / `ConvInteger`，编码器权重为 uint8，解码器为 int8；位置编码表保持 fp32。

**结构上的一个障碍：** fp32 编码器 3.1 GB 中，`MatMul` 权重占 2,415 MB，`Conv` 权重占 635 MB，后者主要是 Conformer 卷积模块里的 1×1 逐点卷积（每层两个，共 32 个）。`MatMulNBitsQuantizer` 只处理 `MatMul` 和 `Gather`，直接套用的话，这 635 MB 会原样保留为 fp32，4 bit 编码器反而比 INT8 编码器更大。因此 `Tools/ASRCodeSwitchEval/quantize_firered.py` 先把满足“核长 1、步长 1、无填充、group 1”的 Conv 改写为 Transpose → MatMul → Transpose（fp32 下与原图逐位一致：随机输入上两个输出的最大绝对误差为 0.0），再量化。

**构建（`quantize_firered.py`，onnxruntime 1.28.0 + onnx 1.19.1 + onnx-ir 1.1.0）：** 4 bit、非对称（带零点）、按块量化，`accuracy_level=4`（激活按块量化为 int8 后计算，是 ARM CPU 上的快速路径，与 INT8 原版的动态量化相近）。所有带常量权重的 `MatMul`（编码器 209 个，其中 32 个来自改写的卷积；解码器 129 个，与 INT8 原版 `MatMulInteger` 的个数相同）以及解码器的词嵌入 `Gather`（`GatherBlockQuantized`）都被量化。剩下 16 个深度卷积、2 个下采样卷积、LayerNorm 和位置编码表保持 fp32。构建只需 8～15 秒，峰值 RSS 7～8 GB。量化器会把默认域的 opset 从 17 提到 21，而导出图中的 `Split` 没有 `num_outputs` 属性，在 opset ≥ 18 下不合法，第一版 4 bit 编码器因此无法加载（`ShapeInferenceError`）。量化器只新增 `com.microsoft` 域的算子，所以脚本在保存前把默认域 opset 改回 17，结果记录在 `quantize.json`。第一版构建已删除；用它跑出的不完整结果留在 `runs-ext/superseded-opset21/`，不参与评分。

| 变体 | 编码器 | 解码器 | 合计 | 文件 SHA256（encoder / decoder） |
| --- | ---: | ---: | ---: | --- |
| INT8 原版（基线） | 779.4 MiB | 397.9 MiB | 1,177 MiB | `54048d66…` / `b840ce71…` |
| (a) `fireredasr2-aed-int4-b32`：全模型 4 bit，块 32 | 522.1 MiB | 264.2 MiB | 786 MiB | `83f69910…` / `b3d22b11…` |
| (a) `fireredasr2-aed-int4-b128`：全模型 4 bit，块 128 | 445.5 MiB | 225.0 MiB | 671 MiB | `e4327b2b…` / `ab6d7d15…` |
| (b) `fireredasr2-aed-int8enc-int4dec-b32`：INT8 编码器 + 4 bit 解码器（块 32） | 779.4 MiB（原文件） | 264.2 MiB | 1,044 MiB | `54048d66…` / `b3d22b11…` |
| (c1) `fireredasr2-aed-coreml-int4-b32`：Core ML，int4 线性量化，块 32（只能在 GPU 上跑，见下） | 437 MiB | 216 MiB | 653 MiB | 见 `models/fireredasr2-aed-coreml-int4-b32/` |
| (c2) `fireredasr2-aed-coreml-pal4k-g16`：Core ML，4 bit k-means 查表量化（LUT），每 16 个输出通道一组，fp16 计算 | 391 MiB | 210 MiB | 601 MiB | 见 `models/fireredasr2-aed-coreml-pal4k-g16/` |
| (c3) `fireredasr2-aed-coreml-fp32-pal4k-g16`：同上，fp32 计算（对照，只跑 ASCEND） | 417 MiB | 244 MiB | 661 MiB | 见 `models/fireredasr2-aed-coreml-fp32-pal4k-g16/` |

**sherpa-onnx 能否加载：** sherpa-onnx 1.13.8 的 Python wheel 内置 `libonnxruntime.dylib`，其版本字符串为 1.28.2，并包含 `MatMulNBits` 内核。(a)(b) 两类模型都能直接用 `OfflineRecognizer.from_fire_red_asr` 加载并解码，`MatMulNBits` 和 `GatherBlockQuantized` 都没有报错。解码设置与基线完全相同，走同一个 `models.py` 分支（CPU、2 线程、`greedy_search`；sherpa 的 FireRed 只实现了 greedy，最多输出 帧数/100×8 个 token），只换了编码器和解码器的文件名。

**(c) Core ML 的做法：** 新增 `Tools/ASRCodeSwitchEval/firered_coreml.py`。

1. **转换：** 从官方 PyTorch 权重 `FireRedTeam/FireRedASR2-AED` @ `2304afed`（`model.pth.tar`，SHA256 `4677cbd3…`）和官方代码 `FireRedTeam/FireRedASR2S` @ `4e7d9aaf` 出发，仿照 sherpa 的 ONNX 接口，包装出两个模型。编码器输入 CMVN 后的 fbank，输出 16 层解码器的 cross-attention K/V 和有效帧掩码。解码器每步输入完整前缀，不带自注意力缓存，输出最后一个位置的 logits。官方解码器的缓存存的是各层输出，所以两种写法计算的是同一个函数。官方的 `_rel_shift` 用了 coremltools 不支持的 `view_as`，改写为等价的 `pad + reshape`。用 coremltools 9.0 + torch 2.7.1 转换为 ML Program：fp16 计算，T 与 L 为可变长度，最低部署目标 macOS 15。编码器转换耗时 45 秒，解码器 17 秒，峰值 RSS 约 9.8 GB。
2. **压缩：** fp16 版为 2,214 MiB。先用 `linear_quantize_weights` 做 int4、对称、每 32 个输入通道一块（c1，653 MiB）。c1 无法在 CPU 上运行，所以又用 `palettize_weights` 做 4 bit 查表量化（c2，601 MiB）。查表有两种取值方式：`uniform` 只需 30 秒，但输出完全错乱，6 条样句都变成重复的单字；`kmeans` 单进程处理解码器就超过 20 分钟，改用 `num_kmeans_workers=6` 后，编码器加解码器共约 5 分钟（需要 `scikit-learn==1.7.2`）。
3. **解码：** 在 Python 中复刻 sherpa 的 FireRed greedy 循环：从 sos 开始，逐步取 argmax，遇到 eos 停止，最多输出 帧数/100×8 个 token，上限 512。特征也按 sherpa 的做法计算：kaldi fbank 80 维、dither 0、`snip_edges`、样本按 int16 量级输入，CMVN 取自发布版 ONNX 的元数据。先用同一套循环驱动已发布的 INT8 ONNX 文件，在 6 条 ASCEND 样句上与 sherpa 的输出逐字相同，说明循环和特征没有偏差；PyTorch fp32 包装模型也给出相同的转写。

**能在哪种计算单元上运行：**

| 模型 | `CPU_ONLY` | `CPU_AND_NE` | `CPU_AND_GPU` / `ALL` |
| --- | --- | --- | --- |
| fp16（未量化） | 可以，RTF 0.28 | 未测 | `CPU_AND_GPU` 可以但很慢（RTF 1.8），每遇到新的输入长度都要重新编译；`ALL` 加载时报 data-dependent shape 错误 |
| c1 int4 线性 | **不支持**（error -7） | 未测 | 6 条样句上可以（`ALL` RTF 0.19）。完整 ASCEND 跑到第 229 条时，MPSGraph 为一个新的输入长度编译了 10 分钟以上仍未结束（调用栈停在 `mlir::mps::StitchedRegion::recurseUses`），只能中止 |
| c2 4 bit 查表（k-means） | **可以**，6 条样句 RTF 0.19，phys footprint 1.7 GB | **不支持**（error -7） | 未用于正式评测（同样需要逐形状编译） |

用 `MLComputePlan` 查看 c1 在 `ALL` 下的分配：编码器的 1,471 个算子全部在 GPU 上，177 个 int4 `linear` 都不能放到神经网络引擎；解码器只有 8 个小算子在神经网络引擎上。原因是 T 和 L 都是可变长度，而神经网络引擎需要固定形状或有限的枚举形状。

**正式评测用 c2 加 `CPU_ONLY`**，greedy 循环和特征与 sherpa 完全相同。在 CPU 上运行时，Core ML 看来会先把查表权重展开成 fp16（footprint 1.7 GB，与 fp16 版相同），所以这里的 RTF 和内存只反映准确率的代价，不代表 iPhone 用神经网络引擎时的速度和内存。

**要在神经网络引擎上运行还缺什么（未做，估计 1～2 天）：**

1. 编码器按时长分桶（例如 2 / 5 / 10 / 20 秒），输入补零，并传入真实长度来生成掩码；用 `EnumeratedShapes` 转换，或者每个桶单独做一个模型。
2. 解码器改用固定长度的自注意力 KV 缓存（`ct.StateType`），交叉注意力的 K/V 按同样的桶补齐并带掩码，避免每一步都改变形状。
3. 用 `MLComputePlan` 确认 4 bit 查表或 int4 在神经网络引擎上真正被采用，再到 iPhone 上测速。

##### 结果：相对 INT8 原版

Δ 为相对 INT8 原版的 MER 差值，配对 bootstrap 95% 区间（`--baseline fireredasr2-aed-int8-20260226`，2,000 轮，种子 20261027），负数表示更好。RTF 和 RSS 取 ASCEND 500 条、单进程测得的值；INT8 原版也在同样条件下重跑了一遍，500 条输出与 10-27 的运行逐字相同。

| 变体 | 体积 | ASCEND 混说（Δ） | CSD test 混说（Δ） | CSD dev 混说（Δ） | CSD 合并 1,511 条（Δ） | 纯中文 CER / 纯英文 WER（ASCEND；CSD test） | 失控 | RTF | 峰值 RSS |
| --- | ---: | --- | --- | --- | --- | --- | ---: | ---: | ---: |
| INT8 原版（基线） | 1,177 MiB | 11.8 | 5.6 | 4.5 | 5.0 | 7.5 / 18.2；2.4 / 11.5 | 0 | 0.341 | 2,909 MiB |
| (a) int4 块 32 | 786 MiB | 11.3（−1.1…+0.0） | 5.3（−0.5…−0.0） | 4.5（−0.3…+0.3） | 4.9（−0.3…+0.0） | 8.2 / 17.5；2.3 / 11.8 | 0 | **0.237** | 1,831 MiB |
| (a) int4 块 128 | 671 MiB | 12.0（−0.4…+0.7） | 5.9（−0.2…+1.1） | 4.5（−0.4…+0.2） | 5.1（−0.2…+0.5） | 7.7 / 17.5；2.2 / 11.7 | 0 | **0.214** | **1,473 MiB** |
| (b) INT8 编码器 + int4 解码器 | 1,044 MiB | 11.4（−0.9…+0.1） | 5.3（−0.5…−0.1） | 4.5（−0.2…+0.3） | 4.9（−0.3…+0.0） | 7.5 / 18.2；2.3 / 11.6 | 0 | 0.330 | 2,756 MiB |
| (c2) Core ML 4 bit 查表，fp16 计算（`CPU_ONLY`） | 601 MiB | 18.6（+4.8…+9.3） | 9.1（+2.8…+4.3） | 8.9（+3.3…+5.8） | 9.0（+3.3…+4.8） | 14.2 / 32.8；5.1 / 17.5 | 0 / 1 | 0.232 | 3,375 MiB（footprint 1.6 GB） |
| 对照：Core ML fp16，未量化 | 2,215 MiB | 19.0（+4.5…+10.4） | — | — | — | 15.0 / 22.5 | 1 / — | 0.237 | 3,506 MiB（1.6 GB） |
| 对照：Core ML fp32 计算，未量化 | 4,428 MiB | 12.1（−0.3…+1.0） | — | — | — | 8.4 / 15.6 | 0 / — | 0.407 | 6,482 MiB（1.6 GB） |
| (c3) Core ML 4 bit 查表，fp32 计算 | 661 MiB | 13.0（+0.4…+2.0） | — | — | — | 8.4 / 19.9 | 0 / — | 0.412 | 5,564 MiB（1.6 GB） |

单位均为 %。

- **4 bit 没有带来可测的准确率损失。** 块 32 的全模型 int4 在三个混说集上都不比 INT8 差，CS-Dialogue test 上甚至略好（区间上界恰好为 0），其余区间都包含 0。块 128 的点估计略差（CS-Dialogue test 5.9 对 5.6），但三个区间都包含 0。所有差值都在 1 个百分点以内，按上文的约定，不应解读为模型差异。三个变体都没有失控。
- **速度和内存的收益主要来自编码器。** 全模型 int4（块 32）体积减少 33%，RTF 降 31%，RSS 降 37%。只量化解码器的 (b) 体积减少 11%，RTF 和 RSS 几乎不变，说明 Mac CPU 上的耗时和内存主要在编码器。`accuracy_level=4` 的 `MatMulNBits` 在 ARM 上走 int8 点积内核，比 INT8 原版的 `DynamicQuantizeLinear` + `MatMulInteger` 更快。

- **Core ML 版的损失主要来自 fp16 计算，而不是 4 bit。** c2（4 bit 查表、fp16 计算）在三个混说集上都显著差于 INT8，高出 3～7 个百分点。为分清原因，在 ASCEND 上补跑了三个对照：未量化的 fp16 版为 19.0%，与 c2 相当；把同一份 PyTorch 权重按 fp32 计算转换（`convert --precision float32`），为 12.1%，与 INT8 无显著差异，说明转换本身正确；在 fp32 版上做同样的 4 bit k-means 查表（c3，661 MiB），为 13.0%，比 INT8 高 0.4～2.0 个百分点，纯英文 WER 由 15.6% 升到 19.9%。也就是说，4 bit 查表本身有一点可测的损失，比 ORT 的按块 int4 大；fp16 计算则带来约 7 个百分点的损失，而且 fp16 版在 ASCEND 上出现了 1 条失控。神经网络引擎只做 fp16 计算，所以要在 iPhone 上用它，先得解决 fp16 的数值问题，例如让 LayerNorm、softmax 和注意力分数保持 fp32（coremltools 的 `FP16ComputePrecision(op_selector=...)`），或者调整这些层的数值范围，然后再做上面列出的形状改造。
- c2 在 CS-Dialogue 合并 1,511 条中有 1 条失控。c3 只跑了 ASCEND，CS-Dialogue 没有跑（约需 2 小时；命令同 c2，模型目录换成 `fireredasr2-aed-coreml-fp32-pal4k-g16`）。
- **速度与内存（Core ML CPU）：** c2 的 RTF 为 0.232，fp32 计算的 c3 为 0.412。phys footprint 都约 1.6 GB；`ru_maxrss` 为 3.4～6.5 GB，其中包括映射进内存的模型文件。这些数字来自 Mac CPU，不代表 iPhone 用神经网络引擎时的表现。
- c1（int4 线性，GPU）在 ASCEND 上跑到第 229 条后中止，部分输出留在 `runs-ext/ascend/fireredasr2-aed-coreml-int4-b32/`，没有 `run.json`，不参与评分。

#### 5. FireRedASR2-LLM

**来源：** 官方权重 `FireRedTeam/FireRedASR2-LLM` @ `2c5e0f41`（Apache-2.0；论文 arXiv 2603.10420）。共 18.9 GB：`Qwen2-7B-Instruct/`（4 个 safetensors 分片，共 15.2 GB，bf16）、`model.pth.tar`（3.6 GB，内含 Conformer 编码器 7.2 亿参数、适配器 2,200 万参数和 LoRA 1.6 亿参数，均为 fp32）、`asr_encoder.pth.tar`（只有结构参数）、`cmvn.ark`。全部 7 个 LFS 文件的 SHA256 与 HF oid 一致，已下载到 `downloads/hf/FireRedASR2-LLM/`。代码为 `FireRedTeam/FireRedASR2S` @ `4e7d9aaf`。

**推理脚本：** 新增 `Tools/ASRCodeSwitchEval/firered_llm.py`，复刻官方 `FireRedAsr2.transcribe` 的 LLM 分支：官方特征提取，提示词「<speech>请转写音频为文字」，`model.transcribe`，`batch_decode`，结果转小写。解码参数采用官方示例 `inference_asr_llm.sh` 的设置：batch 1、beam 3、`repetition_penalty=3.0`、`length_penalty=1.0`、`temperature=1.0`、`decode_max_len=0`（即不超过适配器输出帧数）。脚本只按路径读取 `CORPUS/manifest.jsonl` 和其中列出的 WAV，不含任何语料内容，输出与 `models.py` 相同的 run 格式，可 `--resume`。

**精度与显存：** checkpoint 里的 `use_fp16=0`，官方加载代码会把 Qwen2-7B 建成 fp32，约 30 GB。`--dtype float32` 复现这一默认设置，需要约 34 GB 以上的显存；`--dtype bfloat16` 等同于官方的 `use_half=True`，约 17～18 GB。在 Mac 上，脚本把 LLM 以 bf16 直接加载到 MPS，避免先在内存中构造 fp32 模型。

**GPU 服务器上的运行方法：** 单卡 24 GB 可跑 bf16（A10、L4、RTX 4090 等），40 GB 以上可跑 fp32（A100、H100、H20 等）。语料目录按 `corpus-csd-eval-v1` 的格式拷到服务器（CS-Dialogue 不得外传，只能在本人可控、符合数据集条款的机器上运行）。

```sh
git clone https://github.com/FireRedTeam/FireRedASR2S && git -C FireRedASR2S checkout 4e7d9aaf4482a47cec1724807026b9b151926eb5
huggingface-cli download FireRedTeam/FireRedASR2-LLM --revision 2c5e0f415b9afb8f67cb8b00ea4c54959f70e824 --local-dir FireRedASR2-LLM
R="uv run --python 3.12 --with torch==2.7.1 --with torchaudio==2.7.1 --with transformers==4.51.3 --with peft==0.15.2 \
  --with kaldi-native-fbank==1.22.4 --with kaldiio==2.18.1 --with numpy==2.3.4 --with sentencepiece==0.2.1 \
  --with accelerate==1.12.0 python -I firered_llm.py --model-dir FireRedASR2-LLM --code FireRedASR2S --device cuda --dtype bfloat16"
$R --corpus corpus-ascend-v1 --output runs/fireredasr2-llm --resume
$R --corpus corpus-csd-eval-v1 --subsets csd-test-mixed,csd-test-zh,csd-test-en,csd-dev-mixed --output runs-csd/fireredasr2-llm --resume
```

把两个输出目录拷回本机 `runs-ext/{ascend,csd}/` 后，用 `score.py` 评分即可。

**本地试跑（20 条，停止）：** 上节的 Nano 运行结束、本轮其他任务都暂停后，单独在 MPS 上以 bf16 跑 CS-Dialogue test-mixed 的前 20 条（234 秒音频），解码参数同上。

- **加载：** 第一次失败。transformers 4.51.3 加载权重前会先申请一块与权重同样大的显存（14.19 GB）来预热分配器，Metal 拒绝这么大的单块缓冲区（`Invalid buffer size: 14.19 GB`）。脚本在 MPS 上关掉这一步后可以加载，用时 32 秒。
- **速度与内存：** RTF 为 2.96（解码 693 秒 / 音频 234 秒），首条预热 56 秒。lifetime 最大 phys footprint 为 25.4 GB，其中约 20 GB 是 GPU 内存；运行期间 swap 用到约 8 GB，空闲内存接近 0。照这个速度，全部评测（约 6.1 小时音频）需要约 18 小时，超过约 10 小时的上限，内存也超过约 20 GB 的预算。**按约定停止本地运行。**
- **输出异常，不能作为准确率结果：** 这 20 条的 MER 为 27.6%，同样 20 条上 FireRed AED INT8 为 5.1%。错误主要是删除（109 个）。多条输出以一个与语音无关的英文片段开头，随后有的就结束了，有的接上基本正确的转写。checkpoint 中 LoRA 的键名是标准 PEFT 格式，与 `peft==0.15.2` 一致；不少输出的后半段是对的，说明语音编码与适配器在工作。原因可能是 MPS 上 bf16 的数值问题，也可能是 transformers 在 MPS 上的 beam search 行为，尚未查明。进一步排查每次都要重新加载 19 GB 并大量换页，这里没有继续。
- **在 GPU 服务器上：** 官方代码在 CUDA 上测试过。建议先跑 `--limit 20`，与上述数字对照，确认输出正常后再跑全集。官方 README 报告的 LLM 单条 RTF 约 0.07（GPU），全部 6.1 小时音频在单卡上估计 0.5～1 小时。运行日志在 `runs-ext/llm-pilot.log`，输出在 `runs-ext/llm-pilot/`（只在本机）。

### 附录 F：实验经过与各轮当时的结论

| 日期 | 轮次 | 内容 |
| --- | --- | --- |
| 2026-10-27 | 首轮（实验 2a） | 只有 ASCEND 可以合规使用；在 500 条上比较 11 个模型与变体，并用生产 Swift 路径核对 20 条（附录 E1） |
| 2026-10-27 晚 | CS-Dialogue 复测 | 用户同意条款后，在 test/dev 上复测 5 个模型，排序与 ASCEND 一致（附录 E2） |
| 2026-10-29 | App 新 Nano 运行时 | App 改用自带 Nano 运行时，用同一套语料复测，失控消除（附录 E3） |
| 2026-10-29 | 扩展评测 | 加入 X-ASR、Apple 系统识别、Qwen3-ASR 1.7B、FireRed AED 量化变体，试跑 FireRedASR2-LLM（附录 E4） |
| 2026-10-30 | iPhone 实测与 HF 镜像复测 | 8 个模型在 iPhone 上用 App 引擎实测（第 4 节）；X-ASR HF 镜像版复测；整理为本报告 |

各轮实验最初在实验分支上进行，计划不合入 main；整理为本报告后作为文档提交。下面保留 10-29 时写下的结论摘要和推荐，供追溯；与正文冲突时以正文第 0～5 节为准。

#### 结论摘要（2026-10-29 时）

- **FireRedASR2-AED INT8 在两个数据集上都最好。** ASCEND 400 条混说句的 MER 为 11.8%，SenseVoice 为 14.5%；CS-Dialogue test 730 条为 5.6% 对 8.2%，dev 781 条为 4.5% 对 6.4%，差异均显著。配对 bootstrap 给出的差值 95% 区间为 −3.7～−1.7 个百分点。它在纯中文和句中英文两方面都最好。代价也最大：模型 1.18 GB，Mac CPU（2 线程）上的 RTF 为 0.34，约是 SenseVoice 的 11 倍，峰值 RSS 约 3 GB。输出没有标点，英文全为大写。
- **FunASR Nano（已集成）加上失控保护后排第二，但 App 目前没有这层保护。** 原样运行时，ASCEND 400 条中有 1 条、CS-Dialogue 1,511 条混说句中有 4 条陷入重复循环（例如 "my parents" 重复 120 次），MER 因此分别为 17.3% 和 7.5%（CS-Dialogue test 为 8.3%）。离线模拟“按时长限制 token 数 + 压缩连续重复”后，分别降到 13.3% 和 6.0%（test 为 6.6%）。在 ASCEND、CS-Dialogue test 和合并集上都显著优于基线，在 CS-Dialogue dev 上差异不显著。App 用的是同一组提示词和 `max_new_tokens=384`，所以同样会出现这种循环。**2026-10-29 更新：** App 已换成自带的 Nano 运行时，复测后失控为 0，MER 为 13.2% / 6.7% / 5.1%（ASCEND / CS-Dialogue test / dev），三者都显著优于基线，见 [App 新 Nano 运行时复测](#附录-e3app-新-nano-运行时复测2026-10-29)。
- **Qwen3-ASR 0.6B 不推荐。** 在 ASCEND 上与 SenseVoice 持平（14.7% 对 14.5%），在 CS-Dialogue test 和 dev 上都显著更差（11.8% 对 8.2%，8.8% 对 6.4%）。它会把混说句整句译成一种语言，例如 "computer language" 变成「编程语言」，或者整句输出英文；在 CS-Dialogue 上还有 4 条失控输出。
- **当前默认 SenseVoice Small INT8 仍是很强的基线。** 速度最快，内存最小，体积最小。主要问题是句中英文单词被截断或拼错，例如 "exchan"、"supervis"、"veryryspec"。把识别语言固定为普通话会变差：MER 升到 15.4%，纯英文句 WER 从 18.5% 升到 29.1%。应保持自动识别。
- Paraformer zh（2024-03-09）在 ASCEND 上略差于基线，在 CS-Dialogue 混说上略好，纯英文在两个数据集上都明显更差，不值得替换。FireRedASR2-CTC、Whisper large-v3-turbo、Dolphin small，以及两个方言微调版（SenseVoice 粤语版、Paraformer 川话版）只在 ASCEND 上评测过，均不如基线。
- **建议后续进入 iPhone 与真实录音测试的模型：** ① FireRedASR2-AED（准确率上限；先看手机内存和耗时能否接受）；② FunASR Nano 加失控保护（已有集成，成本最低；保护须先落到 App）；③ SenseVoice 作为对照基线。见[推荐](#推荐与下一步)。FireRedASR2、Nano 和 Qwen3 都发布于 CS-Dialogue 公开之后，不能排除训练时见过它，这三个模型在该数据集上的优势应视为上限。
- **2026-10-29 扩展评测：X-ASR 非流式 INT8 是新的最佳性价比候选。** 它的体积为 167 MiB，Mac CPU RTF 为 0.020，RSS 不到 1 GB；三个混说集上 MER 为 12.2% / 5.9% / 4.7%（ASCEND / CS-Dialogue test / dev），与 FireRed AED INT8 的差异都不显著，而 FireRed 的体积是它的 7 倍，耗时是它的 17 倍。输出带标点和大小写。同一模型的 480 ms 流式版明显差一档（14.0% / 7.5% / 6.2%），而且末尾必须补约 2 秒静音，否则会丢句末的词。Qwen3-ASR 1.7B（12.8% / 8.1% / 5.4%）比 0.6B 好得多，但仍有翻译式改写和 1 条失控，体积 4.5 GB。Apple 系统自带的 `SpeechTranscriber`（zh-CN）中文好、英文差（19.7% / 10.9% / 9.4%），三个集上都显著差于 SenseVoice，`en-US` 会丢掉全部中文。
- **FireRedASR2-AED 可以直接降到 4 bit，准确率不变。** 用 ONNX Runtime `MatMulNBits` 做全模型 int4（块 32；先把 1×1 卷积改写为 MatMul），体积由 1,177 MiB 降到 786 MiB，三个混说集为 11.3% / 5.3% / 4.5%，与 INT8 无显著差异；Mac CPU RTF 由 0.341 降到 0.237，RSS 由 2.9 GB 降到 1.8 GB，sherpa-onnx 1.13.8 可直接加载。块 128（671 MiB）和“INT8 编码器 + int4 解码器”也都与 INT8 无显著差异。Core ML 版用 4 bit 查表时只能在 CPU 上跑：按 fp16 计算比 INT8 差 3～7 个百分点，这是 fp16 数值问题，未量化的 fp16 版同样差；按 fp32 计算时 4 bit 只差约 1 个百分点（ASCEND 13.0%）。FireRedASR2-LLM 在本机 MPS 上 RTF 约 3、内存 25 GB，输出异常，已停止，GPU 服务器脚本已备好。详见[扩展评测](#附录-e4扩展评测新模型与-fireredasr2-aed-量化2026-10-29)。
- **数据：** 首轮只有 ASCEND 可以合规使用，其混说句只来自 5 位说话人，均为香港高校学生。用户当晚同意 CS-Dialogue 条款后，又在其 held-out 集（大陆说话人，test/dev 各 30 人）上复测，排序与 ASCEND 一致，见 [CS-Dialogue 复测](#附录-e2cs-dialogue-复测2026-10-27-晚)。TALCS 官方下载页已不再列出该数据集。

#### 推荐与下一步

| 顺位 | 模型 | 理由 | 真机/真实录音前要做的事 |
| --- | --- | --- | --- |
| 1 | **FireRedASR2-AED INT8** | 两个数据集上混说 MER 都最低，且显著优于基线（ASCEND −2.7，CS-Dialogue test −2.6，dev −1.9 个百分点），中文和句中英文两项都最好 | sherpa-onnx 1.13.8 已支持，Swift 侧需新增模型类型与下载清单。须测 iPhone 峰值内存（Mac CPU 约 3 GB）、单窗耗时，以及编码器能否用 Core ML EP。输出无标点、英文全大写，需要决定是否加标点模型或做大小写处理。 |
| 2 | **FunASR Nano INT8 + 失控保护**（已集成） | 加保护后在 ASCEND（13.3%）、CS-Dialogue test（6.6%）和合并集（6.0%）上显著优于基线，dev 上差异不显著，并且已有下载与运行链路，测试成本最低 | （2026-10-29：App 的新运行时已从解码层面消除失控，见上节；下文为原建议，保留作记录。）**先在 App 中加保护**（本实验只做了离线模拟）：按窗口时长限制生成 token 数（实验用 10 token/s + 16），并压缩连续 4 次以上的重复短语，或检测到循环后回退到 SenseVoice。sherpa-onnx 1.13.8 的 `max_new_tokens` 只能在创建识别器时设定，可以用 20 秒窗口的上限（约 216）代替当前的 384，或按时长分档。另须注意 512 token 上下文只能容纳约 28 秒音频。 |
| 3 | **SenseVoice INT8**（基线） | 速度、内存、体积都最优，混说略逊，纯英文在 CS-Dialogue 上最好；保持 `auto` 优于固定普通话 | 作为对照参与所有真实录音对比 |
| 不推荐 | Qwen3-ASR 0.6B INT8 | ASCEND 上与基线持平，CS-Dialogue test/dev 上都显著更差（+3.6 / +2.4 个百分点），会翻译混说句，并有失控输出 | 不再进入真机测试 |

**2026-10-29 补充（见扩展评测）：**

| 建议 | 模型 | 理由 | 真机前要做的事 |
| --- | --- | --- | --- |
| 新增候选，优先测 | **X-ASR 非流式 INT8** | 准确率与 FireRed INT8 无显著差异，体积 167 MiB，Mac CPU RTF 0.020，带标点和大小写；性价比最高 | sherpa-onnx 1.13.8 的 `OfflineRecognizer.from_transducer` 已支持，Swift 侧接入成本与 SenseVoice 相近；测 iPhone 内存与耗时；在真实录音上看短英文词被写成同音汉字的问题 |
| 替换 FireRed INT8 的部署形式 | **FireRedASR2-AED int4 块 32**（ONNX） | 与 INT8 准确率无差异，体积 786 MiB（−33%），RTF −31%，RSS −37%；sherpa-onnx 1.13.8 直接加载 | 量化脚本与哈希已固定；须在 iPhone 上确认 `MatMulNBits` 的速度与内存，以及 Core ML EP 是否接管编码器 |
| 暂不推荐 | Core ML 4 bit FireRed、Qwen3-ASR 1.7B、Apple `SpeechTranscriber`、X-ASR 流式 | Core ML 版目前只能在 CPU 上跑，fp16 计算会损失约 7 个百分点，要上神经网络引擎需要先解决 fp16 数值问题并重做形状处理；Qwen3 1.7B 太大，且有翻译式改写；Apple 识别英文差；流式版准确率低一档 | — |
| 待服务器 | FireRedASR2-LLM | 本机 MPS 试跑 RTF 约 3，内存 25 GB，输出异常 | 按第 5 节的脚本在 GPU 上跑 |

下一步：

1. ~~用户确认 CS-Dialogue~~：已于 2026-10-27 完成，见上节。
2. **真实录音：** 从用户的 Watch 录音中挑出 20～30 段混说语音，人工校对参考文本后，用生产 VAD 窗口离线比较上表三个模型。重点看产品名、人名和技术词。
3. **iPhone 测量：** FireRed AED 与 Nano 在 iPhone 17 Pro 上的首次加载、峰值内存、单窗耗时和后台可用性；Nano 加失控保护后复测。
4. 如需上限参考，可以从官方权重自行导出 Qwen3-ASR 1.7B，并记录导出脚本和哈希。

### 附录 G：复现

在仓库根目录执行。所有下载和输出都放在已忽略的 `tmp_agent_output/` 下。

```sh
O=tmp_agent_output/asr-code-switching-eval
# 1. ASCEND parquet（固定 revision）放到 $O/downloads/ascend/ 后生成样本
uv run --python 3.12 --with pyarrow==21.0.0 python -I Tools/ASRCodeSwitchEval/corpus.py \
  --test $O/downloads/ascend/test-00000-of-00001.parquet \
  --validation $O/downloads/ascend/validation-00000-of-00001.parquet --output $O/corpus-ascend-v1
# 2. 下载、校验并解压模型；逐个运行（每个模型一个进程）
R="uv run --python 3.12 --with sherpa-onnx==1.13.8 --with numpy==2.3.4 python -I Tools/ASRCodeSwitchEval/models.py"
$R fetch fireredasr2-aed-int8-20260226 --downloads $O/downloads --models $O/models
$R run fireredasr2-aed-int8-20260226 --models $O/models --corpus $O/corpus-ascend-v1 --output $O/runs/fireredasr2-aed-int8-20260226
# 3. 评分（MER、子集、bootstrap）
uv run --python 3.12 --with opencc-python-reimplemented==0.1.7 python -I Tools/ASRCodeSwitchEval/score.py \
  --corpus $O/corpus-ascend-v1 --runs $O/runs
# 4. 生产 Swift 对照（可选）
uv run Native/SpeechVendor/prepare-runtime.py --scratch-directory $O/swift-check/runtime-scratch \
  --output "$PWD/$O/swift-check/sherpa-binaries"   # 运行期间临时链接到 Vendor/SherpaOnnx/Binaries
uv run Native/SpeechVendor/prepare-models.py $O/swift-check/Speech --scratch-directory $O/swift-check/model-scratch
uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/swift_check.py prepare --corpus $O/corpus-ascend-v1 \
  --output $O/swift-check/corpus-20 --count 20
# 5. CS-Dialogue（须先接受数据集条款）：下载、校验、流式抽取、生成评测清单
uvx --from huggingface_hub hf download BAAI/CS-Dialogue --repo-type dataset \
  --revision a84770fcdf14072252373a0227321227eaac7dc7 \
  --include "data/short_wav/*" "data/index/short_wav/*" --local-dir $O/datasets/cs-dialogue
uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/cs_dialogue.py build \
  --dataset $O/datasets/cs-dialogue --output $O/corpus-csd-v1
uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/cs_dialogue.py select \
  --corpus $O/corpus-csd-v1 --output $O/corpus-csd-eval-v1 --controls 300 --max-seconds 20
$R run fireredasr2-aed-int8-20260226 --models $O/models --corpus $O/corpus-csd-eval-v1 \
  --subsets csd-test-mixed,csd-test-zh,csd-test-en --output $O/runs-csd/fireredasr2-aed-int8-20260226  # 可加 --resume
# 6. Nano 失控保护（离线模拟），然后照第 3 步评分（加 --present-only）
uv run --python 3.12 --with tokenizers==0.22.1 python -I Tools/ASRCodeSwitchEval/nano_guard.py \
  --run $O/runs-csd/funasr-nano-int8-20251230 --corpus $O/corpus-csd-eval-v1 \
  --tokenizer $O/models/funasr-nano-int8-20251230/Qwen3-0.6B/tokenizer.json \
  --output $O/runs-csd/funasr-nano-int8-20251230-guard
# 7. App 新 Nano 运行时（2026-10-29）：sherpa 二进制按 runtime-manifest.json 校验后放到 Vendor/SherpaOnnx/Binaries
N=$O/nano-app-runtime
swift build -c release -Xswiftc -enable-testing --package-path Tools/ASRCodeSwitchEval/NanoAppRuntime --scratch-path $N/build
X=$N/build/out/Products/Release/NanoAppRuntime
caffeinate -dims $X run --model $N/model --corpus $O/corpus-ascend-v1 --output $N/runs-ascend/funasr-nano-app-runtime --resume
caffeinate -dims zsh $N/run-csd.sh   # 4 片：$X run ... --subsets csd-test-mixed,csd-test-zh,csd-test-en,csd-dev-mixed --shard K/4 --resume
$X merge --output $N/runs-csd/funasr-nano-app-runtime $N/csd-shards/shard{0,1,2,3}
# 评分目录 $N/score-ascend、$N/score-csd 中另放基线和旧 Nano 的 hypotheses.jsonl 副本，然后照第 3 步评分（CS-Dialogue 加 --present-only）
# 8. 扩展评测（2026-10-29）。每条命令对 ASCEND 跑一次（--corpus $O/corpus-ascend-v1），对 CS-Dialogue 再跑一次
#    （--corpus $O/corpus-csd-eval-v1 --subsets csd-test-mixed,csd-test-zh,csd-test-en,csd-dev-mixed），输出到 $O/runs-ext/{ascend,csd}/<运行名>
$R fetch x-asr-offline-punct-int8-20260603 --downloads $O/downloads --models $O/models      # 流式版同理
$R run x-asr-streaming-480ms-punct-int8-20260605 --models $O/models --corpus ... --output ... --resume
B=Tools/ASRCodeSwitchEval/AppleSpeech/.build/release/AppleSpeechEval
swift build -c release --package-path Tools/ASRCodeSwitchEval/AppleSpeech && $B locales && $B install --locale zh-CN
$B run --locale zh-CN --name apple-speechtranscriber-zh-cn --corpus ... --output ... --resume
uvx --from huggingface_hub hf download Qwen/Qwen3-ASR-1.7B --revision 7278e1e70fe206f11671096ffdd38061171dd6e5 --local-dir $O/downloads/hf/Qwen3-ASR-1.7B
uv run --python 3.12 --with qwen-asr==0.0.6 --with torch==2.9.1 python -I Tools/ASRCodeSwitchEval/qwen3_asr_hf.py \
  --model $O/downloads/hf/Qwen3-ASR-1.7B --device mps --dtype bfloat16 --corpus ... --output ... --resume
uvx --from huggingface_hub hf download csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-2026-02-26 \
  --revision 54e7d658026fff7805acc5a7ad7ee7dd4ca35072 --exclude 'test_wavs/*' --local-dir $O/downloads/hf/sherpa-onnx-fire-red-asr2-zh_en-2026-02-26
Q="uv run --python 3.12 --with onnxruntime==1.28.0 --with onnx==1.19.1 --with onnx-ir==1.1.0 --with numpy==2.3.4 python -I Tools/ASRCodeSwitchEval/quantize_firered.py \
  --fp32 $O/downloads/hf/sherpa-onnx-fire-red-asr2-zh_en-2026-02-26 --int8 $O/models/fireredasr2-aed-int8-20260226 --accuracy-level 4"
$Q --variant int4 --block-size 32 --output $O/models/fireredasr2-aed-int4-b32          # 块 128：--block-size 128
$Q --variant int8enc --block-size 32 --output $O/models/fireredasr2-aed-int8enc-int4dec-b32
$R run fireredasr2-aed-int4-b32 --models $O/models --corpus ... --output ... --resume
C="uv run --python 3.12 --with torch==2.7.1 --with torchaudio==2.7.1 --with coremltools==9.0 --with numpy==2.3.4 \
  --with kaldi-native-fbank==1.22.4 --with onnx==1.19.1 --with onnxruntime==1.28.0 python -I Tools/ASRCodeSwitchEval/firered_coreml.py"
uvx --from huggingface_hub hf download FireRedTeam/FireRedASR2-AED --revision 2304afed56eacfee6256dee5937ed22ffa0b64ec --local-dir $O/downloads/hf/FireRedASR2-AED
git clone https://github.com/FireRedTeam/FireRedASR2S $O/downloads/src/FireRedASR2S && git -C $O/downloads/src/FireRedASR2S checkout 4e7d9aaf4482a47cec1724807026b9b151926eb5
$C convert --checkpoint $O/downloads/hf/FireRedASR2-AED/model.pth.tar --code $O/downloads/src/FireRedASR2S --parts encoder --output $O/models/fireredasr2-aed-coreml-fp16   # 再跑一次 --parts decoder
$C compress --method linear --block-size 32 --input $O/models/fireredasr2-aed-coreml-fp16/encoder.mlpackage --output $O/models/fireredasr2-aed-coreml-int4-b32/encoder.mlpackage   # decoder 同理
#   c2（正式评测用）：--method palettize --palette-mode kmeans --workers 6 --group-size 16，输出到 fireredasr2-aed-coreml-pal4k-g16/，
#   命令 $C 中另加 --with scikit-learn==1.7.2
$C run --backend coreml --compute-units CPU_ONLY --int8 $O/models/fireredasr2-aed-int8-20260226 --models $O/models/fireredasr2-aed-coreml-pal4k-g16 \
  --name fireredasr2-aed-coreml-pal4k-g16 --corpus ... --output ... --resume
# 评分：把 runs/、runs-csd-final/ 中原有运行和 runs-ext/ 中的新运行（只复制 hypotheses.jsonl、run.json）放进 $O/scores-ext/{ascend,csd}/，
# 用第 3 步的命令加 --present-only 评分；再复制一份到 {ascend,csd}-vsfr/，加 --baseline fireredasr2-aed-int8-20260226 评分；
# 量化变体与 INT8 原版另放 {ascend,csd}-firered/，同样以 INT8 为基线。
# 9. X-ASR HF 镜像版（2026-10-30）：逐文件下载并核对 HF LFS oid（见附录 E4），再照第 8 步运行与评分
H=https://huggingface.co/csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03/resolve/ce812cc05d858539a68dd42e86f4fd7a9ce1acf0
mkdir -p $O/models/x-asr-offline-punct-int8-20260603-hf
for f in encoder-epoch-99-avg-1.int8.onnx decoder-epoch-99-avg-1.onnx joiner-epoch-99-avg-1.int8.onnx tokens.txt bpe.model; do
  curl -fL -o $O/models/x-asr-offline-punct-int8-20260603-hf/$f $H/$f; done
$R run x-asr-offline-punct-int8-20260603-hf --models $O/models --corpus ... --output $O/runs-ext/{ascend,csd}/x-asr-offline-punct-int8-20260603-hf
#    评分：与归档版本一起放进 $O/scores-ext/{ascend,csd}-xasrhf/，加 --present-only --baseline x-asr-offline-punct-int8-20260603
# 10. iPhone 实测（2026-10-30）。手机用数据线连接并解锁，自动锁屏设为永不。签名团队与 Bundle ID 读取已忽略的 Config/Local.xcconfig
#     （DEVELOPMENT_TEAM、MOMO_PHONE_BUNDLE_ID），测试 App 的 ID 为 $(MOMO_PHONE_BUNDLE_ID).asrbench；需要 Models/Speech（prepare-models.py）
#     和 Vendor/SherpaOnnx/Binaries（prepare-runtime.py）。所有输出在 tmp_agent_output/iphone-bench/
bench() { uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/iPhoneBench/bench.py "$@"; }   # 函数形式，zsh 下也能正确传参
bench prepare-ascend          # 100 条 ASCEND 混说句
bench prepare-real --pull     # 从已安装的 App 拷出录音（只在本机），按 App 的 VAD 与窗口规划切窗，选约 30 分钟
bench build && bench install   # 生成并构建测试 App，安装后把模型和音频拷进它的容器
bench run                     # 8 个模型 × ascend/fg、real/fg、real/bg；可重复执行，已完成的跳过
bench report                  # 生成 report.md：内存、速度、前后台、手机与 Mac 的 MER
```

Swift 对照需要的 `Vendor/SherpaOnnx/Binaries` 在运行期间以符号链接指向 `$O/swift-check/sherpa-binaries`，运行结束后已删除，没有提交。

### 附录 H：原始产物

均在本机 worktree 的 `tmp_agent_output/asr-code-switching-eval/` 下，没有提交音频、数据集、模型或输出：

- 样本：`corpus-ascend-v1/{selection.json,manifest.jsonl,audio/}`；`selection.json` SHA256 `1b394c9d…`，`manifest.jsonl` SHA256 `ea760a8f…`。
- 每个模型：`runs/<运行名>/{run.json,hypotheses.jsonl,comparisons.jsonl}`；汇总在 `runs/scores.json`（SHA256 `aa8742ac…`）和 `runs/scores.md`；运行日志为 `runs.log` 和 `runs-variants.log`。
- 模型校验：`models/<运行名>.fetch.json`；归档在 `downloads/archives/`。
- CS-Dialogue：分卷与索引在 `datasets/cs-dialogue/`，SHA256 清单为 `datasets/cs-dialogue-short_wav.sha256`；抽取出的 test/dev 在 `corpus-csd-v1/`（11,108 条，34.2 h），评测清单在 `corpus-csd-eval-v1/`。原始运行在 `runs-csd/` 和 `runs-csd-parts/`（续跑的分块），分块清单为 `corpus-csd-*chunk*/`、`corpus-csd-*testmono*/` 和 `corpus-csd-*devmixed*/`；合并计分在 `runs-csd-final/`（含 `scores.md`、`scores.json`、各模型 `comparisons.jsonl` 及 Nano 保护版）。运行与睡眠日志为 `runs-csd.log`，RSS 采样为 `runs-csd-rss.log` 和 `runs-csd-rss-per-process.log`。按数据集条款，这些文件不得提交或外传。
- App 新 Nano 运行时复测：`nano-app-runtime/`。`model/` 为模型目录的 APFS 克隆（App 校验会在其中写入 receipt），`runs-ascend/`、`runs-csd/`（分片在 `csd-shards/`）为输出，`score-ascend/`、`score-csd/` 为评分（含 `scores.md`、`scores.json`），`sanity-*` 为 40 条检查，日志为 `ascend.log`、`csd.log`，RSS 采样为 `csd-rss.log`。源码版本：main `b68c6250`，`FunASRNano.cpp` SHA256 `7574bdeb…`，`SherpaRuntime.swift` `c5d70cd8…`，`SpeechEngine.swift` `b4ad74c4…`。
- 扩展评测（2026-10-29）：新运行在 `runs-ext/ascend/<运行名>/`、`runs-ext/csd/<运行名>/`，运行日志为 `runs-ext/runs-ext.log`，Apple 守护进程的 RSS 采样为 `runs-ext/apple-speechtranscriber-*.daemon-rss.log`；评分在 `scores-ext/{ascend,csd}/`（对 SenseVoice）、`scores-ext/{ascend,csd}-vsfr/`（对 FireRed INT8）和 `scores-ext/{ascend,csd}-firered/`（量化变体对 INT8）。新模型在 `models/`：X-ASR 两个目录及其 `.fetch.json`，`fireredasr2-aed-int4-b32/`、`-int4-b128/`、`-int8enc-int4dec-b32/`（各含 `quantize.json`，记录输入和输出的 SHA256），`fireredasr2-aed-coreml-fp16/` 与 `-coreml-int4-b32/`（`.mlpackage`），构建日志为 `models/quantize-*.log`、`models/coreml-convert-*.log`。官方下载在 `downloads/hf/`（Qwen3-ASR-1.7B、FireRed fp32 ONNX、FireRedASR2-AED PyTorch、FireRedASR2-LLM，`firered-llm.lfs.sha256` 为 LLM 的哈希清单）和 `downloads/src/FireRedASR2S/`（官方代码，固定提交）。
- Swift 对照：`swift-check/run-01/`（生产输出）、`swift-check/runs/`（两种路径的计分）、`swift-check/run-01.log`（含 `/usr/bin/time -l`），源码摘要为 `sha256:1ac1bf3a1facc591daf5a61239e21eac4a382e1ccc7303ee25b58a8fe355afd4`。
- X-ASR HF 镜像复测（2026-10-30）：模型在 `models/x-asr-offline-punct-int8-20260603-hf/`，运行在 `runs-ext/{ascend,csd}/x-asr-offline-punct-int8-20260603-hf/`，日志 `runs-ext/xasr-hf.log`，评分在 `scores-ext/{ascend,csd}-xasrhf/`。
- iPhone 实测（2026-10-30）：在 `tmp_agent_output/iphone-bench/` 下。`results/<模型>--<轮次>/` 为每轮的 `run.json`、`progress.jsonl`（逐窗口内存、热状态、是否在后台）、`hypotheses.jsonl` 和被终止时的崩溃报告；`report.md` 为汇总；`device-run.log` 为运行日志；`data/ascend/` 为 100 条 ASCEND。`recordings/` 与 `data/real/` 是用户本人的录音和切出的窗口，只在本机，不提交、不外传。
