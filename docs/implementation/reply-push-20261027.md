# MoMo-REPLY-PUSH-20261027 · 系统通知

与 `MoMo-REPLY-DELIVERY-20261027` 单独跟踪。现有推送链路已核对并补强，已整合到 `codex/hermes-app-20261021`。用户确认目前没有通知服务，先交付代码与[配置清单](apns-setup-checklist-20261027.md)。**真实系统推送尚未启用，也未验收送达。**

## 现状与阻塞

只读当前 Beta 的运行目录和数据库：`push-gateway.json` 不存在，`push_devices` 为 0，`notification_deliveries` 为 0。没有使用或读取 APNs 密钥，也没有建立外部服务。

已有 `Services/NotificationGateway/gateway.py` 实现 HTTP/2 APNs **alert**；Mac 的 `push_notifications.py` 负责设备绑定、事件/投递落盘、重试和已读抑制。不是 WebSocket 或前台本地通知。`PhoneAppDelegate` 已接 APNs token 回调和通知点击；手机设置 → 通知负责请求授权。源配置含 Beta 的 `aps-environment=development`，但本轮无法读取手机上实际包的签名和系统通知权限。

还需要：

1. 开发者提供可运行的通知网关地址，以及它与这台 Mac 绑定的私有配置文件；按 `Services/NotificationGateway/README.md` 部署或指定已有服务。本轮不部署、不购买服务。
2. 网关操作人员配置 Apple Team/Key ID、APNs 私钥路径和 sandbox/production 环境。没有提供密钥路径，不能判断是否已有有效密钥；本轮没有搜索或读取它。
3. 确认 `com.momoagent.ios.beta` 的 Push Notifications capability、实际签名 profile 与环境一致。源码 entitlement 存在不等于 Apple 签名授权通过。本轮构建关闭签名，不能验证此项。
4. 可用服务及签名 Beta 就绪后，用户在手机设置 → 通知开启授权，再实测后台/锁屏可见 alert 与点击冷启动。当前手机开发连接返回 CoreDeviceError 4016，未查到本次真实 token/权限/安装版本。

## 本轮改动

- 点击通知原先仅滚到底部。现在将经过实例/会话校验的消息 ID 与通知 ID 交给渲染器；目标尚未补回时保留意图，补齐后定位到对应正文。相邻同一任务的中间回复与最终回复可精确区分；重复刷新不会重新定位或重建消息。
- 原生文本兜底也支持消息定位。通知路由不生成用户输入、不审批任务；恢复内容依赖问题1的持久游标链路。
- `final` 通知必须带持久消息 ID，`needs_input` 必须带控件及代次，客户端和网关拒绝无法定位的载荷。
- 设备 token 注册/撤销重试现在尊重网关 `retry_after`，避免服务限流时每两秒重试。
- 设置中服务未配置时明确显示「Mac 尚未配置推送服务」。

## 核对的既有闭环

Mac 只有在 canonical assistant 消息已写入 SQLite 后才投影 final 事件；网络投递不持有聊天写入锁。事件/设备/投递身份分别持久化；重试复用 delivery ID，token 轮换使用 revision，旧 410 不能撤销新注册。已读消息和已呈现的权限确认会抑制尚未发出的通知。锁屏内容是固定的「MoMo 有新回复」，只有不透明定位 ID 进入载荷，无聊天原文、录音或健康内容。

已发给 Apple 的请求无法撤回；网络提交后崩溃仍可能重复。`accepted` 只表示 APNs 接收，不表示手机已展示或用户已读。iOS 挂起后不保证聊天正文静默同步；通知提醒与问题1的内容补齐是不同交付项。

## 验证证据

- `PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python <已有 Beta runtime/venv/bin/python> -m unittest Tests.AgentRuntime.test_push_notifications`：14 项通过。覆盖两设备隔离、重复事件、离线重试、数据库重开、已读抑制、token 轮换、撤销、旧 410、限流等待，以及实际 APNs 序列化器的 alert/隐私/HTTP2/身份保持。Apple 响应用 fixture 注入，无外部投递。
- `swift Tests/Support/chat-notification-focus-smoke.swift`：真实 WKWebView 通过。覆盖冷启动目标先于消息、同任务最终正文定位、重复意图不抢阅读位置/不替换 DOM、新通知定位不同回复。载荷为合成数据，不是 APNs 冷启动实机测试。
- Swift package 的通知解析测试补充 final 缺少消息定位的拒绝路径；与三项合并后的完整客户端测试一起运行。
- 前台、后台、锁屏、未运行、拒绝通知授权、真实 token 更新、点通知冷启动的实机矩阵均未验收；不以单测替代。

Apple 依据：[远程通知服务](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server)、[通知交互处理](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)。部署步骤见仓库的通知网关 README，不在 onboarding 中要求普通用户管理 APNs 密钥。
