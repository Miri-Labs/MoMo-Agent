# MoMo-REPLY-DELIVERY-20261027 · 回复送达

代码已修复并整合到 `codex/hermes-app-20261021` 工作区；未安装、未重启服务、未推送。与 `MoMo-REPLY-PUSH-20261027` 分别验收。

## 证据与改动

- `PhoneRuntime.leavingForeground()` 原先在 `.inactive` 就调用 `RemoteTaskStore.background()`，取消会话订阅和传输；控制中心等短暂中断也会触发。现在只有真正后台才停止普通接收，正在等待的回复使用最多 25 秒的 UIKit 有限执行时间，提前收完、系统撤销或恢复前台都会释放授权。不会取消 Mac 上的任务。
- `ConversationSubscription` 遇到非 URL 错误结束后，Store 仍持有其对象，`refresh()` 因对象非空永远跳过补拉。现在跟踪真实运行状态、自动替换已结束的订阅，保留错误身份校验与授权失效阻断。
- 非订阅补拉原先先落盘再更新 `sharedRuns`，冷启动会读到旧状态；改为先更新再原子保存，失败回滚。
- Mac 的独立 `PersonalAgent.maintain` 与 observer 负责执行和结果投影，订阅断开不取消它们。消息及对应事件在同一 SQLite 事务中保存；补拉沿用原消息 ID 和持久游标，不靠再次发用户消息触发。

## 验证

在隔离分支 `codex/reply-delivery-20261027`：

- `swift test --package-path Packages/MoMoAgentAgentClient --scratch-path /tmp/momo-reply-client-tests`：98 项通过，包括订阅异常退出自动恢复、同实例恢复、冷重开、游标去重。
- `PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python <现有 Beta runtime/venv/bin/python> -m unittest Tests.AgentRuntime.test_conversation_events Tests.AgentRuntime.test_personal_agent`：16 项通过。真实本地 HTTP/SQLite 测试覆盖无订阅时落盘、重开数据库后只补回一份。
- `PhoneReplyContinuationProbe.swift` 与生产生命周期代码编译后通过 `simctl spawn` 执行：短暂 inactive、拒绝后台时间、完成提前结束、到期、恢复后旧回调不干扰新授权均通过。这是注入系统事件的模拟器测试，不是锁屏真机验收。
- 只读当前 Mac 数据库：96 条 assistant、69 条 user 消息；不能据此认定每条手机消息均已成功显示。

## 未验收与边界

本轮 iPhone 开发连接读取失败（CoreDeviceError 4016）；前台、锁屏、后台、断网和重新打开的真实手机验收未完成。现有服务未更新，修复尚不在运行中的 Beta 内。

[Apple 的后台执行规定](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)只提供有限时间，之后系统可挂起。长任务依靠 Mac 持久化和前台自动补齐；系统通知另由 APNs 负责。这里不承诺持续后台连接、强制退出后静默唤醒或实时本地入库。
