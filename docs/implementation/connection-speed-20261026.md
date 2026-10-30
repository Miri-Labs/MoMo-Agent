# Beta 1.34.14：减少提交与首字之间的网络等待

## 源码参考与取舍

核对 Rakazo main `7496079652c5d6e10d767c76bcd46716f2c76df2`。手机进入前台聊天后订阅整个 thread，发送不依赖新建一个 run 的回复订阅；事件从已应用的 cursor 恢复。空闲超时、心跳和有界退避处理失效连接。后端持久事件通过实时通知唤醒读者，数据库仍是事实来源；没有实时通知时才使用补偿轮询。

- [手机前台订阅](https://github.com/elie222/rakazo/blob/7496079652c5d6e10d767c76bcd46716f2c76df2/apps/mobile/lib/thread-live.ts)
- [手机 SSE 与空闲超时](https://github.com/elie222/rakazo/blob/7496079652c5d6e10d767c76bcd46716f2c76df2/apps/mobile/lib/api.ts)
- [持久事件追赶与通知](https://github.com/elie222/rakazo/blob/7496079652c5d6e10d767c76bcd46716f2c76df2/packages/db/src/events.ts)
- [服务器运行与桌面连接](https://github.com/elie222/rakazo/blob/7496079652c5d6e10d767c76bcd46716f2c76df2/README.zh-CN.md)

Rakazo 支持手机、桌面连接同一个已运行的 HTTPS 实例。这与每次穿透到家庭 Mac 不是同一个网络条件；源码不能证明相同网络下它的 RTT 更低。Expo 不是连接速度的原因，也不因此迁移前端框架。

OpenUU 的增量 ICE 和会话恢复也值得参考，但目前默认 Tailscale 路径并不经过旧 RTC 协商。先消除应用层串行等待，不增加另一套 NAT、TURN 或 KCP 协议。

## 本版修改

1. `POST /momo/v1/conversation/messages` 增加可选 SSE 响应，`message_streaming` 能力明确协商。消息持久接收后先发 `run.accepted`，随后同一响应推送原生 Hermes 事件；不再等待 POST 完成才从手机 GET 事件。原 JSON 接收方式和 GET 游标续传保留，旧客户端兼容。
2. 客户端接收回执立即持久化 run ID，交还发送队列；即使上一条回复流尚未结束，下一条仍可发送。回执与首字合并在同一网络块时保留后续帧；有限缓冲溢出显式失败后按原游标恢复。
3. 内嵌 Tailscale 中，交互请求使用独立 URLSession 连接池；历史、转录和健康同步使用原池。两个池共用一个节点及代理，均禁止普通网络回退。仅在前台进入时预热聊天连接，发送不等待预热成功。退出后台取消预热，节点恢复、退出账号时两池一并处理。
4. Access HTTP 与 RTC 透传层保留 SSE、消息体、设备身份、撤销检查及错误状态。断开响应只取消订阅，不取消远端任务；重复提交继续使用原 operation ID。没有更改 Hermes 模型执行循环或新增定时模型请求。

## 验证

- Swift：81 个客户端测试（包含回执/首字合并、回执丢失、错误回执关闭、订阅取消、同时发送两条、无额外 GET、原有恢复与身份约束）。
- Python：3 个真实 HTTP/Access 代理测试，11 个个人 Agent 持久化与回报测试；RTC 10 个检查通过，4 个需要独立外部环境的互操作测试跳过。
- Tailscale 生命周期测试：两个连接池分别复用，共用一个节点；并发、取消、旧会话错误、恢复和关闭顺序。
- Mac 与手机 Beta 构建完成；Mac 签名校验及旧/新 designated requirement 一致，手机/Watch/Widget 安装包 29 项检查通过。

协议测试证明减少了一次串行请求，并不证明公网额外 TTFT 已小于 500ms。真实计时分别报告：本地发送到提交、接收回执、模型自身首 token、手机收到首个正文 token、完整正文首次显示。完整回复显示是另一项指标，不用它混淆模型 TTFT；不使用三个点或已读动画制造性能提升。新版本真实蜂窝/异地网络结果仍待采样。
