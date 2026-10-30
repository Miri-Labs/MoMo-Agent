# 连续人声的顺序转写读取

2026-10-14：J27 的持续人声输入从 30 分钟增加到两小时，旧单窗口路径的丢弃前缀由 12.82 亿帧增至 206.80 亿帧（16.13 倍）。旧路径和原始报告继续保留，见 `Tools/SpeechQuality/DIAGNOSTICS.md`。本次只优化同一读取快照内的重复转换和已消费前缀校验，不改 VAD、窗口 ID、模型、持久分析锚点或原音帧覆盖规则。

## 所有权与屏障

- `SpeechTranscriptionSequence` 是显式的单调用者顺序句柄，绑定创建它的 `SpeechEngine`。内部仍在同一串行 native executor 上运行。它保留一个 `AVAudioConverter`、一个文件读取器和至多配置允许的一窗口 PCM 加 4096 帧读前量；不缓存整个 epoch。
- `TranscriptionInputLease` 固定同 epoch、anchor、generation、配置版本和当时已收到的连续输入。Archive 完整校验后持有原音 lease；它不领取、不完成窗口。每个窗口仍各自领取 attempt，逐次检查当下 descriptor、generation、batch execution 并独立提交。
- 后续窗口只有在每个输入清单和 URL 匹配，且所有快照 lease 仍存活时，才能复用快照。释放过的 lease 不能跳过新领取时的原音校验。新尾端超出快照、锚点/epoch/版本改变、窗口倒序都新建顺序句柄。
- 每个新打开的文件仍执行 byteCount、完整 SHA-256、实际 codec/采样率/声道/解码帧数校验。当前仍有未读尾部的文件，以及已打开且与当前 context 重叠的文件，再次完整 SHA 校验（同文件去重），覆盖跳过静音空隙时的续读与保留的 padding；没有用 stat 命中来免除哈希。已经消费、只剩转换器历史状态的前缀不重新读取。
- lease 只约束 Archive 的生命周期，不保证外部程序不会修改文件。尚未消费的损坏文件、当前续读文件的同路径替换必须失败。已消费的 PCM 是当时验证过的读取快照；单次 hash 与实际文件读取之间的外部原位写入竞态没有在本次扩大为新的安全保证。
- 停止/删除先使持久 attempt 无效。C 调用返回前不会释放窗口或序列的原音；返回后 `Speech.close` 在其 executor 上销毁读取器，再释放 Archive 快照 lease。取消或失败的句柄不允许继续，新执行从已提交锚点重建转换器。
- 普通单窗口 API 保留，既有调用者不自动使用隐藏的跨任务缓存。Phone Coordinator 和压力工具显式选择顺序路径。进程重启也不会恢复内存中的转换器。

## 验证证据与未决记录

证据根 `tmp_agent_output/resume-20261014-syh/`。

- `j27-sequence-frozen-03`：Speech 21 项、Archive 序列 lease 3 项通过；编译前后源码哈希一致。
- `j27-sequence-frozen-04` 与同一测试二进制、不重建的 `j27-sequence-frozen-05-repeat`：每轮 24 项通过，源码哈希一致。6 个输入组合为 16k/44.1k/48k × 实际 PCM/AAC；每组四个窗口包括物理文件尾、跨文件和重叠 padding。`output/sequence-pcm-*.json` 保存源尾界和实际 Float 位模式 SHA，顺序路径、旧 fresh reader、第二次 fresh reader 完全一致。两个采样率的真实 AAC 还经模型比较文本、tokens、timestamps、raw JSON；native 取消后旧句柄拒绝、新句柄恢复通过。
- Archive 三个反例覆盖独立窗口 attempt、持久失效拒绝迟到提交、删除后 lease 释放才移除原音、已释放快照不能绕过损坏文件检查，以及转写修订后旧窗口拒绝提交。
- 首轮 `j27-sequence-pcm-01.log` 原样保留：16k AAC 的 64kbps fixture 设置被系统拒绝；另八个不等断言均来自 44.1k/48k AAC，最大浮点绝对差约 1.3e-7～1.8e-7，散布整个窗口，不只 EOF 或 padding。该轮没有源码/二进制成对哈希，差异具体原因尚未证实，不能宣称已归因于 EOF、余块实现或旧二进制。后续改用平台支持的 16k AAC 24kbps，并增加实际位模式哈希与 fresh→fresh 对照；没有放宽浮点比较容差、修改模型输入预期或窗口规则。

App 新增连续三窗口读取计数和第二窗口 claim 返回间隙删除两个用例。根任务使用包含最终修补的 Debug08 产物执行平台定向回归：TranscriptionIntegration 10 项（含这两个新例）、BatchLifecycle 11 项、后台相关 14 项，合计 **35 项全部通过**，没有运行时 warning。同轮另外 3 项模型恢复测试因无稿假设及错误码预期不符而失败，根任务另行修正并重建；该轮总体是 **35/38**，不能写成全部通过。共享包全套、60/180 秒识别对照以及 30 分钟/两小时新测量以本轮最终报告为准，不能用上述定向通过替代。


## 未读尾部的负向回归

独立审查发现初版仅复核 context 相交文件时，跨静音空隙的下一窗口可能排除仍有未读尾部的旧文件；转换器跳过前缀时仍会消费该尾部。`j27-unread-tail-negative-01` 使用 FileHandle 在原 inode 的未读尾部写入，下一窗口恰从下一文件开始，44.1k/48k 两例均在冻结初版上错误返回 PCM，证明缺口真实存在。修补后把当前 `remainingFileFrames > 0` 的文件无条件加入完整 SHA 检查，并与 context 文件去重。

`package-sequence-final-02` 包含此反例及全部六模块，224 项命名测试中 **223 通过、1 百炼在线测试跳过、0 失败**；编译前后六模块 Sources/Tests 及 Pi Sources 哈希一致。Speech 为 22 项，Archive 为 94 项。原位破坏的负向日志保留，后续成功不覆盖它。修补前的 `j27-optimized-small-01` 与 `j27-optimized-1800-continuous-01` 仍保存对应版本，不能充作修补后产物。

## 最终持续输入复测

最终工具版本 `864db9c...` 下，60/180 秒的 3/9 窗口与同输入旧 API 的 windowID/text/tokens/timestamps 精确一致。30 分钟与两小时全部完成，窗口数仍是 90/360；转写实际转换帧分别为 28,800,000 / 115,200,000，丢弃前缀均 0。旧两小时为 20,795,895,808 次转换帧与 42.047 GB 哈希逻辑字节，新版哈希逻辑字节为 0.920 GB。新旧实际 WAV、窗口帧描述和识别文本哈希的独立比较全部通过。

测量详表与共享主机/压缩内存限制见 `Tools/SpeechQuality/DIAGNOSTICS.md`；原始结果和 SHA 索引为 `tmp_agent_output/resume-20261014-syh/j27-optimized-comparison.json`。最后无存活的 `SpeechQuality` 进程。Debug08 的 35 项相关平台回归通过证明模拟器上的接线和生命周期行为，不能把它或 Mac 的读取优化证明等同设备后台或手机性能验收。
