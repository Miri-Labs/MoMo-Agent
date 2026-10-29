# 说话人分组与可纠正的声纹

版本保持 0.0.1。录音在 iPhone 本地经过现有 sherpa ASR、说话人分段、WeSpeaker 嵌入和档案匹配，结果进入原有转录详情、分享和手机到 Mac 的来源同步。声纹向量保存在本机受保护的 archive.sqlite，不进入远端来源文本。

## 身份与反馈

- 录音内使用匿名说话人编号；不固定为两个人。聚类按固定三秒模型的余弦相似度 0.75 匹配，至少三秒的单人片段才能创建或更新聚类中心。短片段只能匹配已有中心，否则保持未确定。
- 时间线和录音详情统一将说话人菜单放在时间右侧，使用轻量标签，播放按钮保持最右侧；长姓名只截断显示，完整姓名仍提供给辅助功能。菜单提供「这是我」「这不是我」「命名说话人」「撤销本段标记」。自动匹配显示「可能是…」，人工确认才显示确定姓名。
- 「这是我」和命名保存正样本；「这不是我」撤销该片段对本人的正标记并保存负反馈。同一片段再次确认会替换旧反馈。已有其他人的明确姓名不会因「这不是我」丢失。
- 只有人工确认、至少三秒的非重叠语音进入匹配样本。短片段可以修改当前标签，不作为训练样本。自动匹配从不生成新的正样本。
- 「未确认」和没有声纹元数据的旧转录也可手动标记。纯人工标签保存为独立的 `manual-label` 记录，声学证据为 JSON null，不伪造向量、不进入声纹匹配；支持纠正、命名、撤销与忘记身份。菜单明确说明这类标记只影响归属。
- 每个人、每个模型版本保留最早八个锚点和最近五十六个反馈参与匹配，按来源去重；其余证据仍保存，可撤销。声纹匹配使用正样本最高相似度 ≥0.75，与负样本至少差 0.04，与次优身份至少差 0.08；这是保守初值，不是概率或经人群校准的准确率。
- 反馈后重新计算已有未确认归属，保留人工确认；修改会增加转录版本并使旧引用失效。删除录音或移除转录段时同步撤回对应的学习证据。`forgetVoiceprint` 提供删除整个人声纹的档案 API；当前界面以逐段撤销为入口。
- 不修改模型权重，不在手机上微调大模型。改善来自用户确认的多个环境样本和排除样本，不能保证每次反馈都提高整体准确率。语义模型不参与认定声音身份。

## 执行与资源

Pyannote segmentation 3.0 INT8 在 ORT CPU 上处理十秒窗口。独占声轨中连续至少 1.5 秒的语音可提取嵌入；不足三秒重复到固定输入长度，但不参与学习。更短片段可继承同一局部分段声轨的嵌入，同样不学习。重叠片段不提取声纹。

WeSpeaker ResNet34-LM 使用 `[1,300,80]`、内部 FP16 和 FP32 IO，复用现有 sherpa fbank 与 ORT 1.28.2 Core ML EP，设置 `MLProgram`、`CPUAndNeuralEngine`，缓存按模型 SHA 隔离。模型共 14.1 MiB，队列内复用运行时、空闲线程不自旋；不增加 FluidAudio 依赖。

ASR 文本先按原有时间戳重叠规则归属窗口，再按说话时间分段，所有字符必须完整保留。ITN 改写或没有 token 时间戳时，仅在整段声纹一致的情况下赋予单一说话人；混合或无法对齐时保留原文并标为未确定。说话人识别失败写入原始识别记录和日志，成功的转录仍可保存。

schema 13 增加声纹档案、带来源的样本与录音内聚类表；历史 JSON 新字段可缺省，VAD/window fingerprint 不变，不强制重跑旧录音。没有声纹元数据的旧转录不会自动获得姓名或锚点。本次旧音频测试使用独立测试副本，没有修改用户档案。

## 验证

- `MoMoArchiveTests`：244 项通过，覆盖迁移、来源版本、删除、学习撤销、正反纠正、重启、模型版本隔离与禁止自训练；新增无声纹旧片段的纠正、命名、撤销、重启及不参与训练回归。
- `SpeakerAlignmentTests`：完整保留文字、不同说话人切分、ITN 无法对齐时保留未知、单人 ITN 归属。
- iPhone 17e / iOS 27 模拟器默认字号：浅色与深色两轮真实 UI 旅程通过，核对时间右侧对齐、44pt 触控区域、未确认菜单可用，以及「这是我 → 这不是我 → 长姓名 → 撤销」；完整姓名可访问，播放入口可达。静态 UI 扫描无 high 项；两个 44pt 播放触控尺寸的提示已结合实际布局核对。
- `SpeakerNativeTests`：真实十分钟录音和数字静音运行生产 adapter，检查有限单位向量、采样时间范围和取消；本机十分钟推理约 1.7 秒，不含 ASR 和首次模型加载。两个人的主要分组仍需用户按原音确认，没有人工真值，不能报告 DER 或身份准确率。
- 模型导出从固定原版重现至完全相同 SHA256。发布包检查器 23 项通过，增加声纹模型清单检查。
- iPhone + 内嵌 Watch 目标构建通过，包内版本保持 0.0.1。2026-10-29 已完成第一轮真机原位安装、启动与独立版本回读；安装前的 7,757 条接收记录全部保留，资料库身份一致，启动后诊断已刷新。实际 ANE 分配、后台耗电及连续使用表现仍须单独验证。
- 随后的标签布局与旧转录手动标记更新已安装至手机，实际回读为 0.0.1、内部构建 5；正常启动成功、进程保留，更新前 7,765 条接收记录全部保留且诊断刷新。手表此前已安装并启动 0.0.1、内部构建 4；同步构建 5 的两次直接安装被系统既有安装协调器以 `IXErrorDomain/48` 拒绝，腕上仍回读构建 4，不将手机内嵌包视为腕上安装完成。此次后续功能改动仅在手机与其档案层，Watch 源码未变。

本地复现测试（录音不写入 Git）：

```sh
MOMO_SPEAKER_MODEL_DIRECTORY="$PWD/Native/SpeechVendor/SpeakerModels" \
MOMO_SPEAKER_TEST_WAV=/absolute/path/to/mono-16000.wav \
MOMO_SPEAKER_TEST_OUTPUT="$PWD/tmp_agent_output/speakers" \
swift test --package-path Packages/MoMoAgentKit --filter SpeakerNativeTests
swift test --package-path Packages/MoMoAgentKit --filter 'MoMoArchiveTests|SpeakerAlignmentTests'
uv run Tests/Support/test-verify-release-bundle.py
```

## 参考与差异

参考 [Omi STT 架构](https://github.com/BasedHardware/omi/blob/5ba33c951c707586b92d767ec444a1af0c55d04e/backend/utils/stt/ARCHITECTURE.md) 与 [已确认样本学习](https://github.com/BasedHardware/omi/blob/5ba33c951c707586b92d767ec444a1af0c55d04e/backend/utils/speaker_identification.py)，分开管理会话内编号与跨录音身份。MoMo 使用本地 sherpa/ORT/Core ML，不引入 Omi 的云端服务或 Community-1 管线。分段模型采用 sherpa 可用的 Pyannote 3.0；WeSpeaker 的权重许可是 CC BY 4.0，不能用工具代码的 Apache 2.0 许可替代。
