# APNs 配置清单

2026-10-27 用户确认：目前没有通知服务，先交付代码与清单。本轮不创建服务、不读取密钥、不更改通知权限、不安装应用。

| 负责人 | 要配置的内容 | 验证标准 |
| --- | --- | --- |
| Apple 开发者账号管理员 | 为 `com.momoagent.ios`（Beta 测试用 `com.momoagent.ios.beta`） 开启 Push Notifications；准备适用的 APNs Key、Key ID、Team ID，并更新签名 profile | 实际签名包具有 `aps-environment`；不能仅检查源码 entitlement |
| 通知服务维护者 | 部署 `Services/NotificationGateway`，使用它自己的锁定依赖；私钥只放服务器；外层提供 HTTPS | 真实 Apple HTTP/2 请求被接受；网关状态与实例/环境匹配 |
| Mac 配置维护者 | 为实际 Mac instance 生成独立可撤销凭据；私有目录放 `push-gateway.json`（0600），字段为 `url`、`credential`、`environment`、`topic`；正式版 topic 为 `com.momoagent.ios` | Mac 的 push status 返回 configured=true；不将密钥或 token 放仓库、聊天、截图或日志 |
| 手机用户 | 安装有 APNs 签名权限的正式版或 Beta 后，在 App「设置 → 通知」开启通知 | 系统授权成功，真实 APNs token 注册并绑定到该配对设备 |

当前源码使用 **development/sandbox**。TestFlight/App Store 等分发前需让签名包、手机 `MoMoPushEnvironment`、Mac 配置与网关一起使用 **production**。本轮未执行签名验证或切换环境。

Mac 的配置位置为该 Beta 的私有 `Agent/push-gateway.json`；配置生效需要在另行获准后更新/重启对应运行时。详细命令及配置模板见 [通知网关部署说明](../../Services/NotificationGateway/README.md)。此处相对路径以仓库浏览为准；实际文件位于仓库 `Services/NotificationGateway/README.md`。

## 上线前实机清单

- 前台正在看同一条回复：不重复弹横幅；在其他页面可提示。
- 切后台、锁屏、App 未运行：能看到「MoMo 有新回复」，锁屏不含聊天正文。
- 点通知冷启动：不再发一条用户消息，自动补齐并定位对应回复；旧通知不会跳到错误 Mac 或会话。
- 拒绝通知权限：聊天照常，设置正确显示关闭；不自动改系统权限。
- token 变化、网络重试、重复完成事件：设备绑定正确、不会反复重跑任务；核对服务端投递身份。
- 推送失败或服务停机：回复仍在 Mac 持久保存，重新打开可补齐。

APNs 接受、手机显示、用户已读分别记录。测试桩和 HTTP 200 不代表手机锁屏验收；不承诺强制退出后的静默唤醒或绝对送达。

## 本次正式版迁移的签名限制

本机个人开发团队不支持 Push Notifications。1.35.0 本地安装使用 `MoMoAgentLocal.entitlements`（保留 HealthKit，无 APNs）及 `MOMO_PUSH_ENVIRONMENT=disabled`；源码默认发布 entitlement 保留 APNs。后续需要支持推送的开发者团队、对应 App ID/profile、通知网关及 Mac 配置，再重签并覆盖安装。此项不阻塞聊天落盘和重连补齐，不宣称当前已能收到系统推送。
