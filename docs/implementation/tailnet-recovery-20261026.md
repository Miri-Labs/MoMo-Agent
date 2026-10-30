# Beta 1.34.3：保留正常连接，按需恢复本机代理

## 现场与原因

2026-10-26 手机反馈经常出现“连接不可用”。检查时 Mac `/health` 正常、Agent 在线、embedded 入口 connected；手机已保存最近完成的消息。手机 Tailscale 日志有 `UDP is blocked`，但没有足够日志将每次历史报错归因到同一事件。

代码与双 SDK 节点回归确认了恢复逻辑的问题：`PhoneRuntime.leavingForeground()` 在 scene inactive 时暂停手机 Agent；随后每次 foreground 无条件标记重建 Tailscale，健康的节点和 URLSession 也会被关闭。一个请求超时同样会标记整节点重建，影响共用它的聊天、转录和健康同步。原来启动只等待 5 秒，尚未就绪返回普通 `TailnetError.unavailable`，没有进入任务存储层的网络退避状态。

## 修改

- 回到前台或请求发生网络错误，先通过原 SOCKS 代理访问本机 LocalAPI，最多等待 3 秒。同一轮检查由并发请求共享，不读取或发送业务资料。
- 本机代理正常则继续复用原节点与会话；只有本机代理失效或节点状态读取失败才重建。保留原身份目录和配对地址。
- 冷启动最多等待 30 秒；仍未就绪作为可恢复的网络错误交给现有退避重试。登录失效仍保留登录提示。
- 保留私网专用路由、禁止代理失败后回退普通网络、不自动重放 HTTP 写请求、任务原有幂等与游标语义。

## 验证

`Tests/EmbeddedNetwork/RecoveryProbe.swift` 使用两个真实 TailscaleKit 节点和合成控制服务器，不使用用户账号。旧代码仅增加合成控制服务器地址的测试注入，失败于 `Foreground replaced a healthy session`；新代码通过 40 次并发恢复读取、远端失败不重建、本机代理失效后保留地址恢复、旧会话错误隔离和退出账号验证。

手机与 Mac Beta 1.34.3 编译通过，29 项安装包检查通过。Mac 已安装并启动，复查 Agent 在线、embedded 入口 connected。构建、安装和现场复查结果保存在本任务 `outputs/connectivity-20261026/`。真实 iPhone 长时间后台挂起、Wi-Fi/蜂窝切换仍需实际使用验证，不能从本机回归推定已经彻底消除断连。
