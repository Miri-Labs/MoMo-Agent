# Beta 1.31.0：通知与连接恢复

2026-10-24，独立分支 `codex/hermes-app-20261021`。沿用 Mac Hermes、共享对话、手机采集与内置 Tailscale，不增加另一套 Agent runtime。

## 当前交付边界

通知代码、独立 gateway、客户端注册/点击/已读、重连逻辑已实现。Mac Beta 1.31.0 已签名构建；iPhone Beta 完整编译通过，但**当前 Personal Team 不支持 Push Notifications，带 APNs 权限的真机签名失败**。没有删除 entitlement 绕过失败；手机暂不安装。没有真实 Apple 接收、锁屏展示或真机点击的验证结果。

实际运行保持 `system_push=false`，直到配置有效通知服务。缺少服务不阻断聊天、录音、同步或 Hermes 后台完成回报。

## 借鉴 Rakazo 的部分

源码固定 `elie222/rakazo@1e92d28aab97c22e396348a64b2fc2a1e47c9c68`，详见[源码研究与交接](rakazo-notifications-interaction-20261024.md)。按研究、实现、独立验收顺序推进。

- **完成后回来告诉用户。** Hermes 原生任务完成回执唤起后续模型回复；模型最终回复落库后才生成通知。“我开始了”和“后台进程已启动”均不当作任务完成。
- **需要用户时才打断。** 澄清/审批按 run、执行代际、prompt ID 定位；通知点击只打开卡片，不自动回答或授权。最终失败有独立通知，不被已读的开场回复误抑制。
- **通知打开同一段对话。** 先核对当前 Mac/assistant/配对身份，关闭设置或远程画面，再恢复网络、补读真实消息；重复点击去重。推送仅含固定短文案和不透明定位 ID，不带录音、健康、聊天正文或执行指令。
- **明确的重连状态。** 临时网络/408/429/5xx 退避重试，保留 Retry-After；401 停止循环并提供重新配对。旧请求不能把新鉴权失败改回成功。保留草稿、消息和 operation ID，不重新执行不确定任务。

Rakazo 使用 Expo Push Service（后端 → Expo → APNs → iPhone）。本版原生 Swift 客户端直接注册 Apple device token，由独立小服务承担推送 provider。普通用户只需允许通知；Apple 团队密钥和服务部署属于开发者配置，不能放进 onboarding。

## 实现归属

| 层 | 实现与责任 |
|---|---|
| Hermes / 产品投影 | `Apps/MacApp/Runtime/personal_agent.py` 从 settled run、实际工具回执和 pending controls 生成事件；首次升级只记录历史，不补推旧消息。 |
| Mac outbox | `push_notifications.py` 持久化设备、token revision、事件、每设备 delivery；网络发送独立于 Agent 主循环，短暂离线保留待发，过期停止。 |
| 鉴权 | HTTP / RTC 共用 allowlist；设备 ID 来自已批准配对，不信任客户端自报；发送前复核撤销状态，旧 token 失败不能使新 token 失效。 |
| APNs gateway | `Services/NotificationGateway/`，独立 `uv.lock`、HTTP/2、ES256、固定 Beta topic、按实例可撤销凭据；Apple 私钥只在服务端。 |
| iPhone | `PhoneNotifications.swift` + AppDelegate。授权只在设置动作触发；已有授权可自动恢复注册。点击定位与正文补读分开。 |
| 已读与前台 | Web 渲染报告实际可见消息，控制卡按 viewport 判断；下载 cursor 不当作已读，legacy 导入不推进实时已读位置。 |
| 配置 | Beta 专用 entitlement，正式 App 保持原权限；移除 XcodeGen 通用 entitlement 生成配置对 Beta override 的覆盖。 |

通知投递 `accepted` 仅表示 APNs 接受，不能当作手机显示、用户阅读或恰好一次送达。服务重启边界仍可能重复发送；稳定 delivery ID / apns-id 和点击去重限制重复影响。

## 验证

- Swift 客户端 57 项通过：通知解析/去重、离线恢复、401 竞态、503 重试、Retry-After、已读与 legacy。
- Python 合并回归 29 项：25 通过，4 个需要 native WebRTC probe 的场景跳过。修正测试内 Hermes bootstrap 的 import path 泄漏，保证合并运行不改变 Access 的可选依赖发现。
- JavaScript renderer core 与语法检查通过。
- 真实内置 Hermes + 本地脚本模型：后台 process、delegate、客户端离线完成、待输入事件生成/解决后停用；启动短答不推，真实完成报告才生成 final。
- 独立 APNs 协议 fixture 7 项：JWT 公钥验签、sandbox/topic/header/payload、过期 JWT 刷新、410、429、5xx、永久错误、拒绝 HTTP/1 降级。此为本地协议验证，不是 Apple 实网验证。
- Mac 完整签名构建通过；iPhone 完整无签名编译通过。真机签名错误明确为 Personal Team 不支持 Push Notifications / profile 缺 `aps-environment`。

真实 Mac 交互结果、构建日志、协议与原生验收证据保存于工作区 `outputs/apns-rakazo-1.31.0/validation.json`。手机安装、异地后台推送及锁屏点击仍需真机验收，不用编译或测试结果代替。

## 启用真实推送的剩余步骤

1. 选择已加入 Apple Developer Program、支持 Push Notifications 的团队，为 `com.momoagent.ios.beta` 启用该能力并重新签名。当前免费 Personal Team 无法完成这一步。
2. 在该团队创建/提供 APNs token key，由服务端读取，不能提交仓库、放进安装包或发送到聊天。
3. 按 [gateway 部署说明](../../Services/NotificationGateway/README.md) 启动服务并配置每 Mac 实例凭据。个人 Beta 验证可在本机私有运行服务，无需先购买公网服务器；分发给其他用户时统一托管。
4. 开启 iPhone 通知，验证 device token 注册、APNs 接受、锁屏展示、点击回到同一对话；补测 token 轮换、撤销、离线与当前消息可见时的抑制。

开发签名对应 sandbox。之后使用 TestFlight/分发签名时需一起切换构建与服务环境到 production，并读取最终签名确认；不可只改 URL。
