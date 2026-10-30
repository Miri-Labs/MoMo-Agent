# 消息渲染与 Agent 执行分离

日期：2026-10-15。范围：iPhone 助理消息区。用户要求参照 Claude 的实际流式和工具展示，并明确前端与 Agent 分离。

## 决定

`MoMoAgent` 对外提供自己的 Sendable 值：消息身份、轮次身份、有序内容块、工具调用身份/名称/JSON 输入/输出/执行状态，以及消息停止原因。PiDurableKit 类型只在 Runtime 适配。工具结果按调用 ID 关联；纯工具轮次不再丢弃。流式生成与持久消息采用同一逻辑身份。快照是执行事实的只读投影，不能用于回写 Pi。

App 的 `ChatRenderSnapshot` 是唯一的展示协议适配器。`ChatRendererView` 接收展示快照，不导入 MoMoAgent 或 Pi，不读取密钥、档案、数据库，不发模型请求，不启动或取消工具。AssistantModel 继续发命令和订阅 Agent，页面移除只销毁渲染器。

消息区使用 WKWebView 展示随 App 打包的本地 HTML/CSS/JS。选择 WebKit 是为了在同一个排版树中保留 Markdown 表格、代码/公式、文字选择、增量 DOM 和滚动位置；输入框、导航、错误恢复及录音来源页面仍为原生 SwiftUI。仅此处桥接，不建立新的服务层或第二套 Agent 循环。

桥接只允许结构化快照进入页面，以及 ready/copy/link 离开页面。消息字符串不拼进可执行 JS。页面不使用远程依赖；CSP 禁止联网、图片、表单和外部页面，原始 HTML 作为文字处理，生成的 Markdown HTML 继续经 DOMPurify。WebKit 使用非持久存储。来源链接交回现有原生 SourceReference 版本与权限校验，不能仅凭网页 URL 放行。

## 展示行为

- 原样显示用户消息；助理正文使用 16px/24px 的阅读基线，跟随系统字号、深浅色和减少动态效果。
- 按安全块边界提交 Markdown，缓存稳定块，持续更新末尾；非前缀修订重置解析状态，最终提交重新解析以解析后置引用定义。
- 显示节奏按积压量调整，按 grapheme 推进；完成/停止立即展示实际收到的全部文字，恢复历史不重播动画。
- 工具按真实状态展示，过程与单项详情独立展开；结束后默认收起，用户主动展开的状态保留；失败/中断不算成功。
- 记录用户贴底意图，上滑解除跟随，回到底部恢复；正文增长、公式/字体布局变化只在贴底时跟随。流结束播报一次完成或停止状态。
- 复制正文/代码保留收到的原始文本；纯 UI 操作不调用 Agent。

## 来源与依赖

参照 2026-10-15 在登录后的 Claude 中核对的实际页面和公开 bundle，重点为 `shared-10-DMW1MvVo.js` 的 `w7/Zc/g5/yk`、`shared-12-BKD5BeaK.js` 的工具投影和滚动控制、`shared-17-BC-jJIQ7.js` 的状态反馈。实现独立编写；没有打包 Claude 的生产 bundle、服务端协议或专用字体。

离线 Markdown/安全处理/公式/高亮采用有许可证的公开库；版本、tarball 完整性和每个产物 SHA-256 固定在 `Web/vendor/manifest.json`，许可证随资源打包。准备与校验见 [ChatRenderer 工具说明](../../Tools/ChatRenderer/README.md)。这些库只进入 iPhone 资源，不进入 Watch 或 Agent 模块。

私人助理的交流方式在 AgentInstructions 中单独维护，不让模型播报界面进度；来源、时间、删除屏障、工具授权、计划幂等和错误恢复规则继续留在 Agent。

## 验证

纯 JS 检查 Unicode 推进、分块、非前缀修订、引用、工具汇总和滚动意图。Agent 测试检查 live→durable 身份、结果配对、失败/停止/脱敏和真实 Pi 脚本 provider 链路。iPhone 宿主测试加载实际打包的 WebKit 页面，检查 Markdown/代码/公式、脚本隔离、链接桥接、DOM 复用、复制、深色大字体和滚动/停止。测试结果和已知限制另记实施记录，不能用浏览器原型代替 App 验收。
