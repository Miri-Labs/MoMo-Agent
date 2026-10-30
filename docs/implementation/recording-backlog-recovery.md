# 录音积压与后台接收恢复

## 2026-10-16 自动恢复交互修订

用户明确要求取消手动同步交互。下面的“刷新状态 / 重新同步”只属于早期恢复版本；当前界面已移除该按钮及“打开手机 App 重试”的常态引导。

- 封口、传输完成、连接恢复、前台返回及后台唤醒继续自动补位；有待确认片段时，运行时以 30 / 60 / 120 / 240 / 300 秒递增间隔重新核对，收到回执产生进展后回到短间隔，清空或等待用户确认新资料库时停止。
- 额外向 WatchKit 申请 5 分钟后的后台刷新；使用已有 grant 生命周期承接 `WKApplicationRefreshBackgroundTask`，即使没有新的 WC 事件也能恢复。只有一个尚未到期的请求，不依赖定时器阻止进程挂起。系统决定实际唤醒时间，预算不足只记日志，不能把 preferredDate 当作准时执行承诺。
- 文件失败按片段退避，跳过冷却中的文件让其他片段继续；仍遵守最多 4 个系统文件传输。成功文件不因周期恢复无差别重传。
- 自动恢复只重放当前对账请求；手机收到重复请求时允许重放对应响应，手表收到重复回执时允许重放对应确认，系统已排队的控制消息不会重复入队，避免重放全部历史。
- 保留“使用新的手机资料库”确认，因为它改变原音接收方；它不是普通同步操作。本次仍不启用未经真机取消与耗电验证的后台 ASR。

平台依据：[WatchKit background refresh](https://developer.apple.com/documentation/watchkit/wkapplication/schedulebackgroundrefresh(withpreferreddate:userinfo:scheduledcompletion:))。SDK 的单请求限制与系统调度边界已核对。

当前验证：51 项通过，包括 Package 对账 / 原音恢复 11 项（含 503 片）及 Link 27 项、手机宿主 10 项、手表宿主 2 项和无手动同步按钮的 Watch UI 1 项。手表新增测试使用可控制的睡眠边界，确认 30 / 60 秒退避、无界面交互时处理持久回执、清空队列后停止重试；这不代表已验证真实无线链路或 WatchKit 唤醒准点执行。两端模拟器 Debug 构建均通过，已读取最新手表截图。

结果：`/tmp/momo-auto-sync-package.log`、`/tmp/momo-auto-sync-phone.xcresult`、`/tmp/momo-auto-sync-watch-fixed.xcresult`。首轮 Watch 测试 helper 遇到 Swift continuation 类型推断错误，显式标注 Void continuation 后通过，不涉及放松业务检查。

发布路径：Git CLI 仍 TLS 失败，GitHub 连接器已核对远端 main=670d152；使用 Git data API 发布全部已验证改动，按预期旧 SHA 更新远端 main，并核对最终代码树，保留本地已有提交历史。

## 2026-10-16 调查与取舍

用户报告 500 多个录音片段待同步。当前真机在 Device Hub 中 unavailable，尚未取得这次积压的手机 / 手表数据库与日志，不能确定其中多少为未传文件、多少为待回执。

已确认的代码缺口：`PhoneAppDelegate.didFinishLaunching` 原先只注册转写后台任务；`PhoneComposition.make`、WCSession delegate 配置及 `PhoneRuntime.start` 主要由 SwiftUI scene 的 `.task` 启动。系统因 WatchConnectivity 在后台启动进程时不应依赖界面创建。

现有文件链路使用 `WCSession.transferFile`，不以 `isReachable`（即时消息可达）作为文件入队条件，每次最多 4 个系统传输；完成回调继续补位。录音默认每 60 秒封口，所以 500 个完整片段约为 8 小时 20 分钟。手表待确认数统计所有 `ready` 片段，涵盖尚未收到手机持久接收回执的文件，不能等同于手机尚无文件。

修复范围：

- 在 UIApplication launch 中同步创建接收器，再异步恢复资料并激活 WCSession，支持无界面的后台启动。
- 启动恢复及接收事件处理使用有限的 UIKit background task，完成或过期后归还。临时音频仍在 WC delegate 返回前同步移入持久 inbox；超时不删除 inbox，后续启动继续处理。
- 手表“录音信息”提供明确的“重新同步”，复用分页对账、原音补传、稳定回执与确认后清理；普通刷新不再无差别解除所有已完成文件的重传门槛。
- 保留已存在的 4 文件并发与 16 项对账分页，避免一次把 500 多份文件全塞入系统队列。不新增云端上传、丢弃旧录音或强行常驻后台。

现在的积压可先将手表与手机放近，打开两端 MoMoAgent，在手表“更多 → 录音信息”点“刷新状态”（旧版）或“重新同步”（新版），观察待确认片段数是否持续减少。打开 App 是这次恢复的排障办法，不是后台传输的正常前提。已到手机的文件无需等待转写完成才确认。

平台边界：系统决定后台调度与速度，后台传输不能承诺固定时间清空积压；用户强制退出、设备断连、重启后尚未首次解锁等需要在真机复测。手机本地转写有独立 BGProcessing / continued-processing 实现，但 `PhoneBackgroundTasks` 默认 policy 为 `foregroundOnly`，尚未启用后台转写；“等待转写”在关闭 App 后会积压，需要打开手机 App 处理。现有注释将后台转写启用条件定为真机取消与耗电验收通过，本次不靠切换 policy 假装完成验收。文件接收 / 持久回执不等待转写，分别验证。

依据：[Apple WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)、[transferFile](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))。Apple 明确说明文件后台传输由系统调度，且模拟器不支持 `transferFile`，因此逻辑 / 模拟器检查不能代替真机双端后台验收。

## 验证

已通过：

- Package 对账 / 原音恢复 11 项与 Link 24 项，共 35 项。新增 503 片测试中 251 片已在手机但回执丢失，252 片未传输；两端重开、中途对账再重启后，仅补传 252 片，最终待确认与手机回执队列均清零。此为真实 SQLite / 文件的软件链路测试，不是无线传输测试；音频使用短 WAV 夹具，不是 8 小时音频吞吐测试。
- iPhone 模拟器宿主集成 10 项，包括不创建 SwiftUI scene 的 bootstrap 启动、恢复持久 inbox 并生成回执，以及既有接收状态与后台任务过期测试。
- Watch 模拟器宿主集成 1 项：未绑定手机时重试保留原音，不启动麦克风；之后绑定与回执仍能正确清理。
- Watch UI 恢复入口测试 1 项：进入“录音信息”、滚动找到“重新同步”、执行后能返回，未启动录音；已检查截图。
- 两端 Debug 模拟器构建随宿主 / UI 测试通过，`git diff --check` 通过，合计 47 项。原始结果位于 `/tmp/momo-backlog-package-tests.log`、`/tmp/momo-backlog-phone-tests-fixed.xcresult`、`/tmp/momo-backlog-watch-tests.xcresult`、`/tmp/momo-backlog-watch-ui-final.xcresult`。

首轮 iPhone 新测试曾使用无 WAV 容器的裸 PCM，AVAudioFile 正确拒收；已改用现有 PCM16SegmentWriter 产生合法 WAV 后，10 项全部通过。未放松生产接收校验。

尚未完成：真机锁屏接收、后台唤醒、实际清空用户这次积压、新构建安装到用户手机 / 手表；设备目前离线。

Git：开始时工作区干净，main 与本地 origin/main 同为 670d152；多次 fetch（含系统 HTTP proxy）均因 github.com TLS 连接失败，未能确认远端最新状态。修改在独立任务分支完成，通过必要检查后合并到本地 main；远端同步受 TLS 连接失败阻碍，不使用强制推送。
