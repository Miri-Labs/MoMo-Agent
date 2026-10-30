# iPhone 启动、对话反馈与详情加载修复

对应用户 2026-10-16 的六项反馈；完成代码与验证后，从最新 `main` 构建完整 iPhone / Watch 包再安装。原始品牌图标、Avatar 轮廓、inline 引用和通用模型配置保持既有契约。

## 交互与状态修改

1. **启动**：首次使用判断独立读取本地配置，不再等待收件恢复、Watch 对账和资料刷新。升级用户可先进入首页；恢复任务仍由 `PhoneRuntime` 执行，未绕过 durable 收件契约。
2. **Avatar**：第一次出现直接放进目标槽位；仅在两个已显示的槽位之间做移动动画。关闭 WebView 自动安全区 inset，透明页底并消除 SVG inline 基线。首页保持轻微呼吸、转头和眨眼；聊天等待使用同一 Avatar Lab 引擎中较快、幅度较大的 attentive cycle。页面不活跃或开启减少动态效果时停止循环。
3. **发送反馈**：`AssistantModel.send()` 同步产生临时用户气泡，先于建会话、读取凭据和请求模型。观察到 durable 用户消息后替换临时项，不重复持久化或重播进入动画；未受理的发送失败/取消仍走原来的草稿恢复路径。富文本 WebKit 冷启动时先用原生文本气泡绘制，首份 HTML 排版成功后接替。
4. **思考与流式**：等待模型、公开 reasoning、工具执行、正文流和结束状态按可见内容分别呈现。开始正文后收起未手动展开的思考过程；最终正文已完成时，底层收尾不能继续显示“正在思考”。思考标题使用 3 秒中性色移动高光，增量文本短暂淡入；收到的正文立即追上网络内容，不额外排一个打字队列。保留滚动上翻、回到最新、复制、重新生成、inline 来源和取消屏障。
5. **请求竞争**：交互对话忙时取消正在运行的自动卡片/时间线整理，并保留待处理意图；对话结束后续跑。自动整理仍用用户保存的模型和原来的持久化队列。这里没有改变用户模型、偷偷增加外部请求或扩大超时。
6. **转录详情**：加载任务的 identity 只依赖相关内容版本、代次、片段数、处理状态和文件问题，不再依赖每次刷新都会递增的全局计数。无内容变化的刷新不取消阅读任务；新增内容、删除和版本失效仍会重新读取并检查来源。返回后重进的恢复滚动指令延后一个主 actor 调度轮次，等待当前导航布局事务提交，并再次检查内容版本；没有增加固定延时或轮询重试。

主要实现位于 `PhoneRootView`、`AssistantModel`、`ChatRendererView` / Web renderer、`PhoneInsightsModel`、`PhoneBrandIcon`、`RecordingDetailView` 和 `TimelineDetailView`。

## 实际参考与取舍

- **Claude.ai 真实页面与实际加载资源**：在已登录的网页发送了一条合成复盘请求，观察用户消息先出现、Stop 按钮、流式回复和结束后的动作栏；检查 DOM、运行中的 animation，以及入口和已加载 chat 相关 JS。不是只看 Storybook，也没有替换为整站私有代码。
- 本次观察到的 [Claude CSS 资源](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/c6a992d55-DtPVsf7Q.css) 中，用户消息进入为约 450ms，思考文字带为 3000ms；实际用户气泡为 12px 圆角、12px/16px 内边距。MoMoAgent 采用相近的轻量进入、短尾淡入和状态节奏，继续使用自己的中性调色与系统字体。资源地址带版本，不能作为长期稳定 API。
- [Chatbox 消息处理](https://github.com/chatboxai/chatbox/blob/main/src/renderer/stores/session/messages.ts)：本地插入用户消息先于开始生成；对照修复了“先思考、后用户气泡”的状态归属。
- [Chatbox 移动端流请求](https://github.com/chatboxai/chatbox/blob/main/src/renderer/native/stream-http.ts)：对照 setup / starting / active / terminal、取消与迟到事件隔离。继续使用现有 Pi / URLSession 链路，未引入 React / Capacitor。
- [Chatbox 流式落盘协调](https://github.com/chatboxai/chatbox/blob/main/src/renderer/stores/session/streaming-write-coordinator.ts)、[增量淡入](https://github.com/chatboxai/chatbox/blob/main/src/renderer/components/StreamingTextFade.tsx)、[过程收起](https://github.com/chatboxai/chatbox/blob/main/src/renderer/components/chat/useProcessTimelineCollapse.ts)：对照可见更新与落盘的生命周期、终态优先级及正文开始后的过程收起。保留本项目稳定 DOM、增量 Markdown 和 durable 数据约束。
- [Bible Strong Avatar Lab](https://github.com/smontlouis/bible-strong-avatar-lab)：继续使用已固定的真实程序化引擎和原始 MoMoAgent 形状，调整本地 expression / animation 定义；上游来源与许可证见 `Vendor/BibleStrongAvatar/README.md`。
- 设计基线仍为 [iPhone HANDOFF](../design/iphone-review-20261015/HANDOFF.md)、[v8 Pen 稿](../design/iphone-review-20261015/momoagent-iphone-review-v8.pen)、[时间线 Pen](../design/iphone-review-20261015/momoagent-transcript-timeline.pen) 和[首页建议 Pen](../design/iphone-review-20261015/momoagent-home-suggestions.pen)；本次是实现反馈和生命周期修复，没有新增一份外部 HTML 评审稿。

## 验证证据

证据根目录：`tmp_agent_output/device-install-20261016/`（忽略入库）。只按系统默认字号验证。

- JS：Avatar runtime 7 项、聊天 core 14 项通过；生成器核对 24 份固定上游源码哈希。
- Native / WebKit：`final-responsiveness.xcresult` 57 项通过，包含冷 WebKit 前的原生用户气泡截图、Avatar 首次定位/透明 inset/闲置运动/停止、公开思考转正文与完成状态、流式 DOM、取消/复制/来源/滚动、草稿恢复与启动。气泡宽度收齐后的 `final-first-frame.xcresult` 10 项通过（首帧 1 项与 Markdown 9 项）。
- 详情：`final-recording-detail-v2.xcresult` 6 项通过，覆盖相同导航栈返回重进、销毁后重进、短段落与固定播放器、连续 5 次无变更刷新和新转写追加。第一次详情回归抓到了恢复滚动过早的问题；修复后同时重测录音与时间线阅读，没有删除失败用例。`final-navigation-repeat.xcresult` 将原失败的返回重进用例连续运行 3 次，全部通过。
- HTTPS 故障：`http-regression/native-faults/tests.xcresult` 16 项全部通过、0 跳过；用独立临时 iPhone 模拟器和仅本机信任的短期证书运行生产 ProviderAccess → Pi → AssistantModel，不使用真实 Key 或付费模型。检查具体请求次数、阶段超时、部分流失败、重试预算和迟到事件。服务已停止、证书已清理；临时模拟器在原生验证结束后删除。

原有生产预算由 Pi 管理：响应头 30 秒、可观察首字节 45 秒、正文空闲 30 秒、单请求总预算 120 秒，最多两次 HTTP 尝试；持久化逻辑请求另有总期限。测试通过短预算证明期限生效，不通过放宽生产预算隐藏超时。iOS Foundation 可能在首段正文到达时才交付 headers；HTTPS 的 body-delay 用例因此验证客户端可观察的 responseHeaders 期限，不能冒充独立 first-byte 阶段的真机结论。

模拟环境能证明界面与取消/超时契约，不能证明当前用户模型的网络首 token 时延。真实模型速度与两端安装分别记录，不能把旧 main 已安装、iPhone 包内含 Watch 包或模拟器通过当作修复版 Watch 已安装。
