# Core ML 窗口重试与模型预热

在 `codex/sensevoice-coreml-20261017` 合入远端最新 main 后，继续使用现有 FluidAudio、Core ML SenseVoice INT8 和 Sherpa VAD。ASR 保留一套 Core ML 接入，新增当前窗口的 CPU 重试，以及独立于首页和录音的模型预热。本轮不安装设备；版本更新为 1.8.0。

## 窗口执行

正常窗口使用已加载的 `.cpuAndNeuralEngine` 编码器。只有 CTC 检测到非有限数值，或编码器 prediction 返回 Core ML `generic` 错误时，才将同一份特征交给 `.cpuOnly` 编码器重试一次。CPU 编码器按需加载，在窗口内的 autorelease pool 中使用；不常驻第二个编码器，不并发运行同一窗口的两次推理。下一窗口继续使用原加速实例。

取消、形状、精度、词表、query token、模型哈希、文件 I/O 和参数错误沿用原失败行为。Core ML `io` 包含文件错误，不能仅凭错误文字推断为 ANE 问题并切 CPU。CPU 再遇到数值或 generic 推理失败时，返回窗口级识别错误，交给协调器保留原音、安排重试并继续其他自动窗口，不循环重试或写入未验证正文；文件和模型契约错误仍直接返回原错误。取消会在主推理后、CPU 加载后、CPU 推理后和返回前检查；同步原生调用仍须等待返回，期间不会再开一个并发模型。

`coreMLPhases.cpuRecovery` 记录触发原因、CPU 模型加载时间、整个重试耗时和结果，识别原始 JSON 记录 `computeRoute` 与 `cpuRecoveryReason`。旧诊断缺少此可选字段仍能读取。窗口 ID、分析检查点、音频范围、识别指纹和既有提交屏障保留；执行设备变化不改模型身份。

## 准备与复用

1. iPhone 在允许处理的前台状态提交低优先级预热任务，调用方不等待模型准备。首页、同步和录音不依赖该任务完成。
2. `SpeechEngine.warmUp` 在已有识别串行队列校验并加载模型，准备 128、256、512 三种输入形状。并发调用复用一个运行时，已成功的形状不重复预热。分析和 VAD 使用原独立队列。
3. 模型放到 `Library/Caches/MoMoAgent/SpeechModels/<manifest-hash>`，为相同模型保留稳定 URL。每次新进程验证缓存文件，损坏或缺失时从 App 内已校验模型重建；先在临时目录完整复制和校验，再公布最终路径。模型变化使用新目录，不覆盖旧模型身份。
4. 已加载模型在进程内复用。取消期间刚完成的模型加载会先存入运行时，再返回取消；下一次使用无需丢弃后重新加载。每个成功准备的输入档位也单独保留。
5. 进入后台、低电量或热状态不允许处理时，预热取消后续工作。系统已授予的转写后台任务仍可通过原识别队列完成必要准备。普通 App 退出不保证获得后台运行时间。

预热失败只改变设置中的模型状态并记录错误码，保留音频和待转写任务。前台再次触发预热时有 60 秒失败退避，正常转写仍可重试加载。没有新增模型下载或第二套 ASR 回退。

## 加载慢的原因与边界

Core ML 载入 `.mlmodelc` 后仍需针对设备和计算配置进行 specialization。Apple 说明系统会缓存准备结果，可跨启动和重启复用；系统升级、磁盘空间不足或模型文件变化可能清理缓存。缓存与模型完整路径有关，因此本次增加稳定的模型路径，不在每次启动生成随机模型目录。

此前 M4 测试出现首次加载 44.911 秒、第二个进程 0.156 秒，详见[长录音记录](sensevoice-coreml-fix-20261018.md)。这是共享 Mac 上的历史测量，不是 iPhone 启动承诺。预热把准备移出交互路径，不能消除系统重新准备本身的成本；缓存目录也可能由系统回收。CPU 重试临时增加一份编码器的内存，需要真机测峰值、温度和能耗。

本轮真实模型测试中，128、256 帧 CPU 重试成功；一个无间隔重复语音构成的 20 秒压力输入在 512 帧 CPU 推理后仍有非有限值。INT8 是权重量化，图内仍含 FP16 运算，切 CPU 不会把图变成 FP32。此时正确结果是拒绝保存该次正文，保留原音和失败，下一窗口继续使用加速实例。该边界不能宣传为所有数值异常均可恢复；本轮没有加入大体积 FP32 模型或第二套 ASR 后端。

来源：[Apple 模型加载与缓存](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode)、[WWDC23 模型准备](https://developer.apple.com/videos/play/wwdc2023/10049/)、[coremltools 稳定路径说明](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)、[固定 FluidAudio loader](https://github.com/FluidInference/FluidAudio/blob/2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042/Sources/FluidAudio/ASR/SenseVoice/SenseVoiceModels.swift)。

## 验证

- Mac 真实模型与边界定向测试 20 项通过，包含缓存校验与修复、取消、并发预热复用、三个输入档位、CPU 失败后继续加速窗口、PCM 复用及旧结果兼容。对原生缓冲区保持只读，故障注入使用独立的输出数组。
- 跨进程复用：同一个稳定模型目录，本轮第一次预热测试 109.364 秒；相同测试可执行文件在新进程中重跑为 0.653 秒。该测试含模型校验和加载、三个尺寸预热、VAD 分析及双预热调用的一致性检查。未清空系统全局缓存，首次数字受共享 Mac 负载影响，不是严格冷启动分布或手机性能承诺。
- 模型准备离线测试 3 项通过，发布包检查器自身回归 21 项通过。
- iPhone 与内嵌 Watch 的 arm64 模拟器 Release 编译通过，实际发布包静态检查 27 项通过；两端及 Widget 版本均为 1.8.0。未安装或启动设备 App。
- 最后补充 generic 重试用尽时的窗口错误归类；恢复策略 6 项全部通过，文件与取消错误继续保留原类型。
- [分支 CI](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39143805961) 通过，包含档案、协议、语音边界和前后台协调器编译。该次 CI 的代码提交为 `5ab9574`；后补的错误归类由上述 6 项本地测试覆盖。最终 main 检查见 [GitHub Actions](https://github.com/xilanhua12138/MoMoAgent/actions/workflows/agent-archive-tests.yml?query=branch%3Amain)。
- 全量语音测试曾复现已记录的 AAC 顺序读取与新读取器逐位相等断言失败，共 24 条断言；相关读取器与此测试相对最新 main 未修改。真实 AAC 转写对照通过。该已有边界保留，不把定向通过称为全量通过。

运行产物位于 `tmp_agent_output/20261018-coreml-recovery/`：`final-acceptance-tests.log`、`warm-relaunch-tests.log`、`tests/coreml-cpu-recovery.json` 及模型和发布检查器日志。手机首启、后台恢复、峰值内存、温度及耗电尚待同一真机版本验收，本轮不安装设备。
