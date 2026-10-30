# 识别后端耗时与兼容性复测

此工具只在显式设置 `MOMO_SPEECH_BENCHMARK` 时编译。正常应用和质量评测入口不启用该代码。它使用已固定的模型、公开音频和生产 `SpeechEngine`，保留失败记录。

## 编译与运行

在自己的 worktree 中使用独立的 scratch。以下命令中的路径均相对此 worktree，运行输出必须位于新的 `tmp_agent_output/` 子目录。

```sh
xcrun swift build --package-path Tools/SpeechQuality \
  --scratch-path Packages/MoMoAgentKit/.build --force-resolved-versions \
  -c release -j 2 -Xswiftc -enable-testing -Xswiftc -DMOMO_SPEECH_BENCHMARK

uv run --no-project Tools/SpeechQuality/source-version.py
```

将上一条输出作为 `SOURCE_VERSION`，运行已编译的 `SpeechQuality`：

```text
SpeechQuality --backend-benchmark MODEL_DIRECTORY CORPUS_DIRECTORY NEW_OUTPUT_DIRECTORY SOURCE_VERSION MODE [SHARED_INPUT_ROOT]
```

主要模式：

| 模式 | 内容 |
| --- | --- |
| `micro-coreml` / `micro-sherpa` | 独立进程只加载指定后端，在 utility 串行队列运行 9 种时长各 2 次，包含首次切换形状的成本 |
| `pipeline-only` | 20 条原始 FLEURS 音频，再运行 60、600、3,600 秒拼接压力输入；60/600 秒各 3 次，3,600 秒 1 次 |
| `pipeline-reverse` | 与上一项相同，先运行 Core ML |
| `pipeline-coreml` | 仅运行 Core ML 的原始句子和完整长录音流程，用于新进程重载及长录音复测 |
| `pipeline-dense` | 固定官方中文样本中的 70,000 帧连续重复，分别运行两后端的 60 秒完整流程；不添加句间静音 |

三个常规 `pipeline-*` 模式可传入 `SHARED_INPUT_ROOT`，复用其中已存在的 `audio-60`、`audio-600`、`audio-3600`。缺少目录会失败，不会补写共享输入；这样可以在不同构建和进程中保持长输入的源 UUID 与窗口身份一致。

`micro-only` / `full` 的微测部分会同时保留两个运行库，并交替调用。它们用于复现早期测量条件，**不能代表应用只加载一个后端的耗时**。`load-only` 同样同时保留两运行库，只记录初始化。

## 输入和计时口径

- FLEURS 固定 `google/fleurs` 的 `cmn_hans_cn` test，revision 为 `70bb2e84b976b7e960aa89f1c648e09c59f894dd`。选择最短 6 条、中位附近 6 条、最长 8 条，逐文件校验 SHA。音频为公开朗读语音，署名及 CC BY 4.0 信息保存在 corpus manifest。
- 微测用上述公开音频按顺序连接，每句后加 0.5 秒静音，再截取 2、5、7.5、7.9、10、15.2、15.7、20、20.6 秒。该部分检查时长/形状与数值有效性，不计算 CER。
- 常规长输入循环上述连接音频，写成 60 秒 PCM16 分片。两后端复用同一批实际文件和 manifest。它表示长文件的离线存量处理，不代表一小时自然会议的识别质量。
- 连续型使用 SHA 为 `b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373` 的官方中文样本，裁取规则复用原诊断工具。
- 原始句子及长输入使用生产 VAD、窗口、准备流、PCM 缓存、顺序读取和识别接口，保留原来的 20 秒核心与 padding。模型初始化计入首次识别，同时通过独立字段记录。常规长输入在自然句子之后运行，通常已加载模型；连续型第一次调用包含初始化，须扣分项后解释。
- 每个微测调用记录完整 wall time、模型 native 时间及 Core ML 分项。原有双后端微测有 2 轮预热和 7 轮测量；独立后端模式不排除首轮，以便检查首次形状切换。
- 编码器或 CTC 出错时保留耗时和错误；失败的长输入不计算有效吞吐。部分完成窗口只从诊断记录计数，不能把失败调用的返回时间当作整段完成时间。
- `coreMLPhases` 为可选诊断字段，包含缩放、预处理、补齐、编码器、CTC、结果编码及输入档位。CTC 失败附带结构化原因和位置，不保存音频或正文。旧诊断缺少该字段时仍可读取。

`natural.jsonl` 保存参考和识别文本。CER 使用现有 `score.py` 的 `normalize`、`edits` 和 `aggregate`；失败样本按空假设保留在分母。小样本比较与完整语料质量验收分别解释。

首次初始化、首次形状专门化、复用后推理和整个录音处理分别报告。共享 Mac 的结果须记录系统版本和并行负载，不能替代 iPhone 的耗时、温度、内存及耗电验收。
