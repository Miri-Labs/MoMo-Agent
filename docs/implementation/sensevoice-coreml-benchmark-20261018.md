# Core ML 长录音复测

**本页保留 `7607c2b` 修复前的失败记录。** 模型复用后的短窗口有提速，但初始化、切换输入形状时的反复编译，以及一小时任务中的 ANE 编译失败，会抵消收益。此前只有约 5 秒短样本的结果不足以判断是否适合全天录音。后续本地修复与磁盘充足条件下的对照另见 [输入配置修复记录](sensevoice-coreml-fix-20261018.md)。

所有测量在独立 worktree 完成，没有合并 main、推送或安装设备。基础实现为 `a0519a3`，模型与 FluidAudio pin 保持不变。

## 测量环境与口径

- Apple M4，10 核 CPU，16 GiB 内存，macOS **27.0 / 26A428**，Release `-O`。本机存在其他构建活动，曾因磁盘接近满盘进行缓存清理；命令行进程的缓存、签名和模型准备条件也与手机应用不同。时间用于定位问题与比较趋势，不作为独占设备基准。
- 同一份 Sherpa CPU / 2 线程配置、同一份 Silero VAD、同一生产 `SpeechEngine`；保留 20 秒核心、padding、窗口身份、PCM 复用和顺序读取。
- 从固定 FLEURS 中文 test 选择 20 条原始录音，长度 4.26～23.86 秒。常规长输入将这 20 条录音依次连接，每句后加 0.5 秒静音，再重复至指定时长。两后端使用完全相同的 WAV 和 manifest。
- 60 秒、600 秒各 3 次，3,600 秒 1 次，使用同一个引擎复用模型；先 Sherpa，再 Core ML。长输入在原始句子测试之后运行，已经加载识别模型。
- 长文件是合成压力负载，FLEURS 是朗读语音，均不能代表全天手表环境的完整识别质量。Mac 结果不替代 iPhone 的耗时、温度、内存、耗电和后台验收。

固定模型：`FluidInference/sensevoice-small-coreml@74bdbe74b2258f25b5400db72f6cbfbef7c74ded`，FluidAudio 为 `2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042`。FLEURS 为 `google/fleurs@70bb2e84b976b7e960aa89f1c648e09c59f894dd` 的 `cmn_hans_cn` test。

## 完整生产流程结果

| 输入 | Sherpa CPU | Core ML INT8 |
| --- | --- | --- |
| 1 分钟，3 次 | 0.952、0.965、0.956 秒；均完成 11 窗口 | 0.311、0.310、0.311 秒；均完成 11 窗口 |
| 10 分钟，3 次 | 8.861、8.913、9.390 秒；均完成 74 窗口 | **101.082、3.068、102.525 秒**；均完成 74 窗口 |
| 1 小时，1 次 | **76.372 秒，447 窗口完成** | **失败**；39.144 秒后返回错误，失败前完成 72 个窗口 |

1 小时的 Core ML 返回时间表示部分处理后失败，不能换算成整段吞吐或加速比。10 分钟第二次复用时约快 2.9 倍，但另外两次超过 100 秒，因此不能只挑最快的一次作为性能结论。

20 条原始句子两后端均完成，使用现有 `score.py` 的归一化与编辑距离：Sherpa 为 62 / 841，CER **7.37%**；Core ML 为 63 / 841，CER **7.49%**。这个小样本主要检查迁移是否产生明显质量偏差，不是完整中文质量验收。

另测 60 秒连续人声压力型：重复原诊断工具的官方中文裁片，不添加句间静音，生产 VAD 产生 **3 个完整窗口**。两后端均完成。新引擎首次处理的 wall time 为 Core ML **105.638 秒**、Sherpa **1.757 秒**；其中模型加载分别为 **104.958 秒**、**0.407 秒**，累计 native 分别为 **0.239 秒**、**1.028 秒**。Core ML 三次编码器调用均为 bucket 512，耗时 75、61、60 毫秒。这组说明连续长窗口可以正确且快速执行，初始化代价仍主导首次处理；不能把常规长流程失败解释为“512 档位必定不支持”。

## 慢在哪里

生产流程首次加载 Core ML 编码器耗时 **107.865 秒**。另外几次新进程加载为 97.709、108.068、196.311 秒，主机负载和缓存状态不同，不能把这些值当作严格控制后的冷启动分布。

10 分钟首轮有一次编码器 prediction 耗时 **98.019 秒**，对应 feature frames 162、bucket 256；预处理为约 1.3 毫秒。第二轮整个任务只用 3.068 秒，第三轮又出现长等待。

在等待期间，对本轮 `SpeechQuality` 进程进行 1 秒采样。识别线程的栈为：

```text
FluidSenseVoiceRuntime.recognize
MLModel.predictionFromFeatures
MLE5ProgramLibraryOnDeviceAOTCompilationImpl
MILCompilerForANE
_ANEClient.compileModel
同步等待 ANE 编译返回
```

1 小时任务最终返回 `com.apple.CoreML Code=3`，底层为 `ANECCompile() FAILED (11)`。失败窗口的 feature frames 为 **86**、bucket 为 **128**，因此问题不能简单归为只在最大档位出现。系统日志还记录了 Core ML 编译器的 `Cannot retrieve vector from IRValue format`；这些信息支持继续排查模型导出、形状专门化与当前系统的兼容性，尚不足以把根因全部归于某个系统版本。

模型 MIL 的默认长度为 1,800，而本应用最大上下文约 344 个 feature frames。Apple 说明默认形状在模型初始化时加载，其他形状首次预测可能额外准备。默认长度过大是后续导出优化的候选因素，本轮没有通过修改模型产物验证其具体收益。[Apple：Flexible Input Shapes](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html)

加载器已设置 `.cpuAndNeuralEngine`。Core ML 的 reshape frequency 默认也是 `frequent`，因此不能把“补上这个开关”当作已经解决重编译；还需要实测形状切换与模型准备策略。[Apple：reshapeFrequency](https://developer.apple.com/documentation/coreml/mloptimizationhints-swift.struct/reshapefrequency-swift.property)

这份 INT8 文件压缩的是权重。MIL 中 352 处权重解量化输出为 FP16，没有 activation quantize/dequantize；这不是全程 INT8 运算。Apple 区分权重量化与激活量化，二者同时量化才可能利用新 ANE 的 INT8 计算优化。[Apple：Quantization Overview](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-overview.html)

## 微测交叉检查

早期微测在同一执行上下文保留两个运行库，交替识别。9 种时长各 2 次预热、7 次测量；Core ML 的 15.2、15.7、20、20.6 秒输入在 7 次测量中均出现非有限输出，其余时长通过。该条件不等于应用只加载一个识别后端，不能用它认定生产长窗口必定产生 NaN。

随后用**独立进程、只加载 Core ML、utility 串行队列**复测相同 PCM：9 种时长各 2 次，**18 / 18 完成，均无非有限输出**。5 秒约 18.4 毫秒、10 秒约 24.2 毫秒、20.6 秒约 66.7 毫秒，均为两次的中位数，包含首轮调用。共存、执行上下文和缓存状态同时存在差异，本轮没有把差异仅归于某一个因素。

通用模型的 `MLComputePlan` 返回 CPU 和 unknown，未标出 ANE；实际等待栈又明确显示正在尝试 ANE 编译。因此通用计划不是各个运行时形状的实测硬件占比，不能据此断言整段推理都在 CPU 上运行。上游也记录了 FP16 在 CPU/GPU 路径出现 NaN 的限制，硬件存在和 `.cpuAndNeuralEngine` 配置不能单独作为结果正确与性能通过的证据。[FluidAudio：SenseVoice](https://github.com/FluidInference/FluidAudio/blob/2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042/Documentation/ASR/SenseVoice.md)

## 本轮代码与证据

- 增加可选 `coreMLPhases` 及结构化 CTC 失败位置，保留旧诊断兼容。编码器和解码器抛错时也记录分项耗时。
- 增加显式编译开关下的后端测试入口；默认应用不引入基准逻辑。失败输入保存错误与诊断，长任务失败不填造完成窗口。
- 复测命令与输入口径见 [BACKEND_BENCHMARK.md](../../Tools/SpeechQuality/BACKEND_BENCHMARK.md)。本轮产物在 `tmp_agent_output/20261018-coreml-benchmark/`，常规流程 source digest 为 `sha256:8727b8ce57cae8788f1401e265cf7d0afffb35d581b6685c7ff92a8770e4cc10`。
- `pipeline-03/` 保存全部 40 条自然句子结果、14 次长任务记录和逐调用诊断；`micro-02/` 保留共存微测，`isolated-coreml-05/` 保留独立后端复测，`dense-06/` 保存最终分项计时代码下的连续型复测。各目录保存模型 manifest hash、源码摘要及可执行文件 SHA。旧版本测量源文件另存快照，原失败目录没有覆盖。
- 独立检查两后端自然样本的 ID 与参考文本，并重新校验全部 71 个长输入 WAV 的 SHA、采样率、声道、位深、准确帧数及 manifest 连续性，通过；结果为 `pipeline-03/input-inspection.json`。
- 最终诊断代码的 Debug 定向回归：9 项通过；另 1 项需显式开启的真实模型用例跳过，本轮真实模型由上述 Release 基准覆盖。首次尝试整包 Release 单测时，既有 Archive 测试引用了只在 `#if DEBUG` 内提供的计数器，编译未通过；没有修改无关 Archive 代码。随后按 Debug 测试配置通过定向回归，最终 Release 基准工具也重新构建通过。
- `pipeline-03-process-sample.txt` 为本轮单进程采样，`pipeline-03-coreml-system-log.json` 仅查询本轮识别进程和 ANE 编译服务的编译/错误信息。`encoder-compute-plan.json` 为通用计划，不是硬件执行 trace。
- 按用户授权运行 Mole 1.50.0：purge 清理本轮 Baseline `.build` 约 1.19 GB；clean 清理可再生缓存约 1.91 GB，跳过系统级清理，临时保护 Xcode、CoreDevice、项目和浏览器目录，结束后恢复配置。`ranges` 仍保留。密码未使用，未写入产物。

## 后续实现优先级

继续保留 Core ML 方向，但先解决模型准备和形状兼容性。优先比较面向本应用 20.6 秒上限重新导出的固定形状与小范围枚举形状，确认同一实例在往返切换形状后仍稳定复用，并分别记录准备、识别与失败阶段。默认形状、导出产物或解码规则变化必须更新识别指纹并重新验证质量，保持原有录音窗口与历史数据兼容。

正式替换前，必须先通过重复 10 分钟和完整 1 小时任务，再在同一 iPhone 测量吞吐、能耗、温度与后台恢复。现阶段不应把当前 INT8 产物直接作为已经验证的手机性能优化交付。
