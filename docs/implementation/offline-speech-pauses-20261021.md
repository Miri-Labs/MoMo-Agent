# 离线转录保留句中停顿

连续讲话被切成许多短片段的一个原因是离线 VAD 沿用了输入框语音的 0.5 秒静音阈值。超过阈值的换气会结束语音段，窗口规划器随后为每段分别建立识别窗口。

## 采用的策略

参考 [Meetily 的分段修复与验证记录](https://github.com/Zackriya-Solutions/meetily/pull/679)，离线导入及重新识别使用 2 秒静音阈值，实时输入使用 0.5 秒。该项目的 [import.rs](https://github.com/Zackriya-Solutions/meetily/blob/main/frontend/src-tauri/src/audio/import.rs) 保留了离线参数。

MoMoAgent 在创建档案分析用的 `SherpaVAD` 时采用 2 秒阈值。继续使用现有的连续 VAD、最多 20 秒的识别核心窗口、跨文件读取和断点机制。输入框语音继续使用原参数，不引入新模型、声纹或额外的文本合并器。

两个语音段之间不足 2 秒的静音留在连续的原音范围中。读取时保留其中的全部样本，时间戳仍对应原音。达到静音阈值或 20 秒窗口上限后可以分段。长静音可以不送给识别模型，原音本身始终保留。

## 已保存数据

这项设置只用于运行时的离线 VAD，沿用现有动态 VAD 灵敏度的配置方式。全局配置指纹、已保存窗口和断点保持有效。改变全局指纹会使历史分析覆盖失效，导致重新扫描和识别；本次不触发这类历史迁移。

新规则应用于之后分析的音频。已经分段的历史转录和已登记的待识别窗口不会自动重新分段。

## 验证

基线为 `bf7c2b5db9c157460040fd262d2dff459744094e`。以下结果来自 macOS 本地测试，使用现有真实 Silero VAD 模型及中文语音样本，不代表手机上的耗时或识别准确率测量。

- 拼接 15 组“3 秒语音 + 1 秒静音”，另加首尾静音，总长 64 秒。修改前生成 15 个识别窗口，修改后生成 3 个；每个核心窗口不超过 20 秒，核心覆盖连续。
- 两段语音之间停顿 1 秒时生成一个窗口。文件边界位于停顿中间，合并范围的解码样本与原始 PCM 逐样本一致，1 秒静音完整保留。
- 停顿 3 秒时仍生成两个窗口，中间的静音正确计入无语音覆盖。
- 真模型定向回归共 5 项、15 个参数场景通过，覆盖分段、批次续跑、进程重建、取消恢复、VAD 灵敏度变化后读取已登记窗口，以及未确定的语音边界。
- `MoMoSpeechTests` 无模型模式通过，涵盖输入框窗口、文件边界、重采样、取消和音频读取。该模式跳过需要真实模型的测试；上述定向回归单独启用了真实模型。
- `git diff --check` 通过。本次没有打包或安装手机、手表应用。

复现真模型定向回归：

```sh
MOMO_SPEECH_MODEL_DIRECTORY=/path/to/Models/Speech \
swift test --package-path Packages/MoMoAgentKit \
  --scratch-path tmp_agent_output/offline-pause-tests --jobs 2 \
  --filter 'RealSpeechTests/(archive|batchAndRestart|checkpointDoesNotCommit|thresholdChange)'
```

模型目录需包含项目现有的 `manifest.json`、`silero_vad.onnx`、SenseVoice 模型、词表和 `test_wavs/zh.wav`。
