# 手表录音在其他 App 播报后的恢复

用户反馈使用滴滴时，手表录音会被打断。本次修复中断后的恢复路径，版本为 1.12.6。

## 已确认的代码问题

- `WatchRuntime.recoverCapture` 对 30 秒内的第二次恢复直接返回。没有延迟任务，连续两次中断就可能让录音一直停住。
- `.interruptionEnded` 把 `shouldResume` 当作继续录音的必要条件。它是系统对自动恢复播放的提示；当前产品应依据用户是否仍在录制来决定是否重新申请麦克风。
- 系统没有发出中断结束通知时，`WatchMicrophoneGate.interrupted` 一直为真。旧状态甚至会拒绝用户手动发起的新激活。
- 自动恢复遇到系统明确的 `insufficientPriority` 错误后直接失败，没有后续重试。
- 音频回调先开始清理、中断结束通知随后到达时，恢复请求可能落在保存诊断与设置 `finalizing` 之间。此时也需要保留请求，待清理完成后执行。

以上是代码证据，不能据此认定滴滴这次触发了全部路径。2026-10-20 本轮设备枚举中，手机为 unavailable。手表一度可列出应用支持目录，随后目录查询超时；读取录音账本返回 CoreDevice 4000 / RemotePairing 1001，未取得这次中断的诊断事件。

## 修复行为

1. 中断开始时关闭输入、保留录制意图，按现有规则结束当前采集段并保存已采集资料。
2. 收到中断结束后，仍在本进程录制且用户未暂停或结束时，尝试启动同一会话的新采集段。记录原始 `shouldResume` 值供诊断；是否能实际录音仍由系统激活结果和内置麦克风检查决定。
3. 第一次自动恢复可以立即执行。之后每 30 秒最多执行一次，冷却期间合并为一个延迟任务，不轮询麦克风，不扫描录音目录。任务等待期间不持有运行时或数据库资源。
4. 仅对明确的系统优先级拒绝继续安排重试。权限、存储、编码和清理错误保留失败状态，不进入无限重试。
5. 新中断取消旧的延迟任务；暂停、结束、删除录音也会取消它。执行前再次检查会话代次、用户意图、中断状态以及旧采集段是否已清理，迟到的回调不能重启已停止的录音。
6. 用户手动继续会重新申请音频会话，允许摆脱缺失结束通知留下的旧标记。新的中断仍会使本次激活失效，且仅重置标记不会打开输入。
7. 音频服务重置会清除旧服务的中断标记，但仍需重新激活并验证麦克风。冷启动恢复历史会话仍要求用户轻触开始。

保持 `.record` 类别和内置麦克风校验。没有通过开启扬声器、耳机输入或压低其他 App 音量来避开中断。系统占用麦克风期间的声音无法补录，时间线应保留真实缺口。

## 依据

- [Apple：处理中断](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)：音频会话被其他会话打断后需要重新激活；开始与结束通知不保证成对出现。
- [Apple：shouldResume](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionoptions/shouldresume)：该值是恢复播放的提示。本次依据持续录制意图恢复采集，是本产品的行为选择，不是 Apple 对所有录音 App 的要求。
- 本机 WatchOS 27.0 SDK 的 `AVAudioSession.h`：通话占用麦克风时，录音激活会以 `insufficientPriority` 拒绝；`setPreferredInput` 在 watchOS 不可用。

## 验证

验证日志位于本任务 `tmp_agent_output/20261020-watch-interruption/`。

- Mac 上运行完整录音模块测试，80 项通过，耗时 6.479 秒。覆盖延迟恢复、重复请求合并、新中断替换、暂停/结束取消、手动重试、优先级拒绝后的再次安排、等待期间对象释放，以及账本中断与容量保护。
- 将当前生产源码中的 `WatchAudioEvent`、`WatchMicrophoneGate` 原样提取到临时 Mac 测试包，复用仓库里的输入门控测试，仅替换模块导入名称。7 项通过，包括缺失结束通知后的手动重试、新中断使激活失效、音频服务重置与门控关闭。它验证门控代码，不模拟 AVAudioSession，也不代表真实手表录音已验证。
- 使用 `generic/platform=watchOS` 完成 `MoMoAgentWatchTests` 的 `build-for-testing`，结果为 `TEST BUILD SUCCEEDED`。编译包含新的输入门控测试；没有执行模拟器或真机测试。此次关闭签名的编译产物仅用于检查，不用于安装。
- 新增原生采集回归用例：没有播放恢复提示时继续同一录音会话，保留前后采集段；用户暂停后迟到通知不再重启。该用例沿用现有原生输入测试设施，本轮未执行。
- 未验证滴滴播报、接听电话、连续导航提示在实际手表上的恢复时间和录音缺口；未安装 1.12.6。需要设备开发通道恢复后用已签名 Release 包完成这些验收。
