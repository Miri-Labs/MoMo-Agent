# 收到手表录音后立即接续后台转录

## 问题与证据

用户反馈：即使手表每隔几分钟同步，打开手机仍可能看到约 50 分钟的转录延迟。

本轮读取了正式手机的接收诊断、转录性能快照和资料库副本。快照时间为 2026-10-20 20:30 左右，早于本次修复安装：

- 手机已有 3,486 个录音片段，其中 20 个仍待处理，覆盖当天 20:06:59 至 20:26:59。
- `processing_failures` 没有记录，已有的 6,074 个分析窗口均已完成。快照显示后台仍有原生转录调用。
- 部分短窗口识别约需 0.04 秒；120 秒音频的准备耗时包含下游等待。该证据支持“已经收到的音频仍在排队”，不能单独解释用户报告的完整 50 分钟。

代码中存在明确的后台入口缺口。`PhoneReceiveCoordinator` 将录音持久化后通知 `onAudioReceived` 和 `onChanged`；此前只安排波形、调用 `requestWork()` 并提交 `BGProcessingTaskRequest`。转录协调器处于 `systemSuspended` 时，单纯请求工作不会启动识别。退出前台时已有短时接续，但后台收到新录音时没有对应的执行入口。

## 改动

1. `ReceivedAudioTranscription` 复用现有 `TranscriptionTaskGrant`。后台收到新录音时，通过 UIKit 申请有限运行时间，并启动 `startBackgroundAutomatic`。同一批连续收件共用一个任务。
2. 工作完成后立即释放系统运行时间。系统到期时同步结束 UIKit 任务，再通过已有停止屏障取消未完成的转录尝试，保留已提交结果。过期回调带代次检查，不能停止后来的任务。
3. `BGProcessingTask` 或用户发起的持续后台任务接管时，先等待短时任务完成停止屏障。系统任务存续期间，新收件交给同一个转录协调器，避免重复申请短时任务。
4. 自动后台请求提交后记录 pending 状态；每次收件不再替换同一个待调度请求。系统投递后重新安排下一次请求。进程重启后先查询系统已有请求。
5. 用户暂停、严重热压力和低电量模式仍遵循既有策略。抬腕同步、录音分片、批量传输和最近录音优先规则不变。

## 系统边界

Apple 明确规定：[同一标识的请求会替换已提交的请求](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submittaskrequest%28_%3Acompletionhandler%3A%29?changes=_6)。这次合并重复提交，但没有证据证明替换请求本身造成了固定 50 分钟延迟。

UIKit 的[后台延长运行](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)有时间限制；[后台任务的执行时机](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)由系统决定。修复利用收到录音时已有的唤醒机会，不能把手表的同步间隔当作手机后台执行的固定时钟。

## 验证

测试使用 `Tools/PhonePipelineReplay`，直接编译应用的生命周期和提交逻辑，并用真实中文语音、实际 Core ML 模型和资料库验证“界面始终未进入前台也能转录”。

覆盖连续收件合并、系统拒绝运行时间、入队期间过期、旧回调隔离、持有者释放、系统任务交接、重复提交、提交期间投递，以及取消后重新提交。

本轮 10 项回归全部通过。真实语音测试先触发了 30 秒超时；进程采样定位到 `MLModel` 加载和 Core ML 设备编译。测试改用与既有 Core ML 测试一致的 180 秒初始化上限后，79 秒完成，返回预期中文文本。这个时间包含 Mac 模型初始化，不作为手机转录吞吐量。

真机验收需另外核对：从主屏幕离开 App、持续录音、在未附加调试器的情况下等待同步，再比较录音时间、手机持久化时间和转录提交时间。Mac 回归及构建通过不能替代这项验收。

## 本轮交付

- 代码提交 `a6aef48` 已合并到远端 main。Release 版本为 1.17.5，内部构建号为 83。
- 手机、手表及 Widget 构建通过；实际包版本、模型资源、签名和手机内嵌 Watch 包一致性检查通过。
- 手机覆盖安装成功，设备应用列表确认版本为 1.17.5。启动被系统以 `Locked` 拒绝，因此尚无新版本的后台运行证据。
- 安装后读取的接收诊断仍是此前版本于 21:01 写入的快照。资料库身份相同，原有 3,486 个片段 ID 均保留，并多出 30 个片段。这只能证明旧快照仍可读取，不能代替新版本启动后的资料核对。
- 手表更新失败在开发隧道建立阶段：`CoreDeviceError 4000 → RemotePairingError 1001`。没有开始应用传输，不能记作腕上已更新。

本轮日志及冻结产物位于忽略目录 `tmp_agent_output/20261020-background-transcription/`。诊断数据库用 XZ 无损压缩，并核对压缩前与解压后的 SHA-256；未改动手机原始资料。
