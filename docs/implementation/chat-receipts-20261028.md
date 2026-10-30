# 聊天回执：已送达 → 已读 → 隐藏

用户要求区分送达和阅读，并参考 Dots bundle。回执由真实执行事实驱动；UI 不设置倒计时，也不强制每个中间状态停留。

| 事实 | 回执 | 三点 |
| --- | --- | --- |
| 仅本地保存，Mac 尚未确认 | 隐藏 | 隐藏 |
| Mac 接纳到持久队列，尚未领取 | 已送达 | 隐藏 |
| Hermes 领取输入、开始处理 | 已读 | 等待回复时显示 |
| 助手回复已出现在消息区 | 隐藏 | 隐藏 |

普通输入以原生 admission 的 `execution_generation` / running 状态确认领取。generation 在 claim 时分配，终结后仍保留；重开 App 不靠 UI 缓存猜已读。补充输入的 generation 可以先绑定运行，因此必须等 `delivery_state=applied` 才算已读，pending/steering 仍为已送达，not_applied 不显示成功回执。服务端用户回声本身只能证明送达；优先综合同一 operation/run 的已有事实，避免回声到达时把已读降回已送达。

`AgentMessageReceipt` 负责状态映射，`ChatRenderSnapshot` 给手机和 Mac 提供相同事实。只给最新用户消息显示一行回执；SwiftUI 原生首帧与 WebKit 一致。正文与回执独立，更新文字保留同一文本节点，只对回执出现/消失做透明度过渡。图片/文件消息同样支持。已送达和已读都不代表任务完成。

## Dots 参考证据

2026-10-28 只读检查本机 `/Applications/ChatGPT.app/Contents/Resources/app.asar`，版本 26.1021.31345：

- `webview/assets/local-conversation-turn-c6fca0c05e97.js`，SHA-256 `cddff908dc0f8107fee997275d77b4b97e60d149838edfc4e5f6bb4becab81c8`。
- `aeon.userMessage.read` 的中文翻译为「已读」，英文为 Read；所查模块没有独立 Delivered 展示。
- 最新 outgoing 的独立状态元素、右对齐小号灰字、opacity 过渡、initial=false、减少动态效果时无过渡，不参与复制和点击。
- Dots 的 accepted 门控与约 1500ms 显示等待不等于 MoMo 的运行事实。MoMo 增加真实送达阶段，不照搬定时等待；处理很快时允许直接显示已读。

仅参考行为，自行实现；没有复制分发其 bundle 或源代码。

## 验证

- `swift test --package-path Packages/MoMoAgentAgentClient --scratch-path tmp_agent_output/receipt-package-tests`：108 项通过，覆盖排队、领取、终结后恢复、过时回执、补充未消费/已消费/拒绝。
- `swift Tests/Support/chat-read-transition-smoke.swift`：真实 macOS WKWebView，在亮色、暗色、减少动态效果、阅读历史、英文五种模式下运行本地发送 → 送达 → 已读 → 回声 → 回复；消息位移 0px、气泡透明度始终 1、无节点移除/入场动画重播。附件回执通过。
- `swift Tests/Support/chat-history-stability-smoke.swift`：21 行交错回复，20 次刷新，零 DOM 移动与动画重播。
- `node --test Tests/Support/chat-renderer-core.test.cjs` 与 `node Tests/Support/chat-localization.test.cjs` 通过。
- `xcodebuild ... -only-testing:MoMoAgentIntegrationTests/ChatRendererTests/testReceiptStateMachineShowsDeliveredThenReadAndDotsWithoutMovingBubbles -only-testing:MoMoAgentIntegrationTests/ChatRendererTests/testCompletedStatusKeepsDotsUntilSharedReplyIsRendered test`：iOS 27 模拟器两项通过，覆盖真实 RemoteTaskStore 日志 → snapshot → WKWebView、回声保持身份、失败、完成状态先于正文到达。
- iPhone / 内嵌 Watch / Mac Release 构建通过，手机发布包静态审计通过。手机使用既有本地签名 entitlement（现有 provisioning profile 不含 APNs），不改变推送服务状态。
- 上述 WebKit 验证使用合成消息，只验证真实渲染器；不代表异地网络或用户手机的端到端验收。
