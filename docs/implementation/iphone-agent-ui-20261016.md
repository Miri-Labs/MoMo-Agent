# iPhone Avatar 与对话输入修复

本轮处理 iPhone 首页 Avatar、原生输入框及其会话生命周期。最初基线为 `origin/main` 的 `3d70be3`，工作分支为 `codex/iphone-agent-ui-20261016`，原始独立提交为 `b879b64`。用户随后明确要求修复多会话并合入 main，此提交已由 `f8ca4e0` 纳入 `codex/iphone-parallel-chats-20261016`，与[独立会话及单层思考区修复](parallel-conversations-20261016.md)一起交付。main 后续的 Watch 波形、录音读取修复和设备安装记录保留。

## 用户要求

- Avatar 在自己的位置出现，不从左上角或其他页面飞入。
- 保留原角色，静息时有小幅转头、倾斜和眨眼；用户明确说明白条是横穿耳朵或头部的直线，不是耳朵之间的留白。
- 点输入框即可弹出软件键盘，并能继续输入和修改草稿。
- 实际查看 Claude.ai 的前端 bundle，并对照高星移动端 AI 聊天实现；落实状态、输入和流式生命周期，不能只改静态外观。

## 实查来源与取舍

下列 star 数为 2026-10-16 GitHub API 的当时快照。源码按 commit 固定，避免将后续上游修改混入此次结论。只借鉴行为和生命周期，没有复制这些应用的界面或引入它们的依赖。

| 来源 | 版本与当时 star 数 | 具体检查 | 本项目采用的行为 |
| --- | --- | --- | --- |
| [Chatbox](https://github.com/chatboxai/chatbox/tree/0ac6385ae1ff5bf778777826da3c5edcd55b61b8) | `0ac6385`，42,032 | [messages.ts](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/renderer/stores/session/messages.ts)、[原生流桥接](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/renderer/native/stream-http.ts)、[流式持久化协调器](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/renderer/stores/session/streaming-write-coordinator.ts) | 先插入用户消息，再进入模型生成；取消与终态只清理一次；流式检查点不能盖掉终态。本基线已有本地 outgoing 气泡、原生首帧与终态渲染，本次保留并回归验证。Chatbox 在自动压缩之前仍有等待，本项目不照搬这段等待。 |
| [RikkaHub](https://github.com/rikkahub/rikkahub/tree/72747fc9e9198364b0e0747cfef791a76f6f5eac) | `72747fc`，8,198 | [ChatPage.kt](https://github.com/rikkahub/rikkahub/blob/72747fc9e9198364b0e0747cfef791a76f6f5eac/app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatPage.kt)、[ChatInput.kt](https://github.com/rikkahub/rikkahub/blob/72747fc9e9198364b0e0747cfef791a76f6f5eac/app/src/main/java/me/rerere/rikkahub/ui/components/ai/ChatInput.kt)、思考消息组件 | `Scaffold.bottomBar` 持有输入区，输入区处理 IME 和导航安全区。本项目用单一 SwiftUI `safeAreaInset` 承载原生输入，不随空首页/消息区分支重建。 |
| [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai/tree/83b884b2cedc0f16983bde983c1f4dbbf16bbc8c) | `83b884b`，8,667 | [ChatInput.tsx](https://github.com/a-ghorbani/pocketpal-ai/blob/83b884b2cedc0f16983bde983c1f4dbbf16bbc8c/src/components/ChatInput/ChatInput.tsx)、[useChatSession.ts](https://github.com/a-ghorbani/pocketpal-ai/blob/83b884b2cedc0f16983bde983c1f4dbbf16bbc8c/src/hooks/useChatSession.ts)、ChatScreen | 输入控件持有稳定 ref；生成 lease 的 abort 立即清理 UI，finally 再统一收尾；取消后的 token 不继续更新画面。对应检查本项目取消、草稿和 renderer 终态，避免重复再建一套请求管理。 |

### Claude.ai 实际加载资源

使用已登录浏览器访问 `https://claude.ai/new`，检查编辑器 DOM、移动视口与当前页面加载的入口、共享 JS、CSS。没有发送测试消息，也没有把浏览器视口模拟当作 iOS 软件键盘验证。iOS 键盘另由原生 UI 测试检查。

资源来自 `https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/`，其中：

- `shared-m-1-CG9OTp1A.js`，SHA-256 `d80f892acfae86ff21006ea77ca9fd4df732c40ccd4b1a47eda2c74f8c68189d`：`D7` 按 `isLoadingBeforeStream`、工具运行、`isStreaming` 区分 thinking/shimmer/writing/idle；消息数据区分临时 human/assistant UUID 与持久消息；完成判断结合 stop reason 与 in-flight 集合。
- `shared-m-2-DddI6DoO.js`，SHA-256 `34a795400ae821651895e353a76619c6572919e926db859638d1a0f5af6530be`：移动键盘观察区分 visualViewport 缩小与页面缩放，避免把缩放误当键盘；相关原生行为由 SwiftUI 安全区承担。
- `shared-l-m-0-X_ezdY_M.js`：区分 `text_delta` / `thinking_delta`，并观察 `message_start`、内容块和 `message_stop`；记录用户消息绘制与流式帧的时机。不能据这些遥测函数推定整个 Claude 请求实现。
- `c6a992d55-DneHncv1.css`：用户消息有单次轻微缩放/淡入，思考文字有 3 秒 shimmer，提供 Reduce Motion 分支。本项目已有同类用户气泡入场、思考带和短尾部淡入；不叠加逐字排队或人为延长等待。

以上是此次加载版本的观察，不是 Claude 稳定 API。原始资源、文件摘要和开源代码快照只保存在被 Git 忽略的 `tmp_agent_output/iphone-agent-ui/references/`，不作为应用代码分发。

## 实现

### Avatar

- 删除根页面的坐标 preference / 全局 Avatar overlay，以及根据全局坐标移动的动画。首次体验和首页各自在实际布局内放置角色。
- 按 slot 尺寸直接布局 WKWebView，不再把固定 280 点网页放进外层缩放。禁用网页滚动与自动 content inset，背景透明。
- 实时网页内容与透明点按按钮分开作为同一固定大小容器的子节点，点按范围只覆盖角色自己的 slot。输入框区域没有角色覆盖层。
- 去掉外层持续缩放，静息动作由原 Avatar Lab 程序化几何产生：小幅左右转头、轻微倾斜；每步 1.4 秒过渡、0.8 秒停留，首个眨眼约 1.7 秒，此后间隔 3.5–6.2 秒。
- 活跃页面、前台 scene 且未开启减少动态效果时播放；页面离开、后台或减少动态效果时停止。点击角色仍保留局部招呼反馈。
- 没有改角色头部、耳朵和眼睛的原始几何，也没有用图片替代。横线是否在用户真机彻底消失，需要安装后现场复核，不能仅凭某一张模拟器截图判定。

### 输入与消息

- 单一原生 `TextField` 始终挂在整个 Assistant 页面外层的 bottom safe-area inset，空首页、首条消息、流式和完成状态共用。
- 简单 HStack 明确分配输入宽度，编辑区最低 44 点，最多六行；系统处理键盘安全区，发送/停止按钮留在键盘上方。
- 流式期间可以编辑下一条草稿；打开菜单、转录后返回保留草稿。发送与取消继续使用既有 AssistantModel 和 Agent 请求生命周期。
- 保留已有首帧原生用户气泡、WebKit 就绪交接、收到正文后结束等待、取消保留部分回复、inline 引用、增量 Markdown 与阅读位置逻辑。
- 离线资源检查器原先只认识 Markdown 清单，因已存在的两个 Avatar 产物而失败。现在同时运行 Avatar 的独立可重复生成检查，并把这两个经过检查的文件列入允许集合；其他未知文件仍使检查失败。

## 验证记录

只用系统默认字号，专用 iPhone 16 / iOS 27 模拟器；不启动 Watch，不动其他任务设备。

- Avatar bundle 可重复生成检查通过；24 份固定上游源码哈希一致。
- Avatar 运行时 7 项受控时钟测试通过，覆盖实际几何变化、眨眼、绘制上限、停用零调度、唯一 clip ID、销毁与思考动作。
- 原生 WKWebView 的 120×120 视口、实际角色像素、持续几何变化、停用后静止均已观察。旧测试沿用 overlay 的 safe-area 坐标预期不适用于局部布局，改为原生 host 的实际 safe-area 中心。
- 首轮真实首页测试在首次点击后、调用 `typeText` 前已观察到软件键盘；随后继续输入并点角色后再次编辑通过。
- 导航往返编辑草稿、菜单搜索/新聊天保留草稿已通过复测。
- 最终整屏 Avatar 像素检查与首点键盘、导航返回编辑、菜单搜索/新聊天草稿保留共 3 项 UI 用例通过，0 失败。两张实际截图分别记录输入前与首点软件键盘出现后，角色在自己的 slot 内，未见横穿头部的白线。
- 最终 `ChatRendererTests` 14 项原生 WebKit 用例通过，0 失败：包括首帧用户文本、正文到达后结束思考、增量 DOM、取消、重新生成桥接、引用、阅读位置、暗色与减少动态效果。不是外部模型速度测试。
- 完整 `testStopRegenerate503RetryCitationPlaybackAndRelaunchPreserveDraft` 通过：本地合成 SSE 经真实 App/Pi/URLSession/WK 链路，包含停止、重新生成、两次 503、显式重试、inline 引用、原生回听控制与重启保留草稿。独立只读账本检查通过：4 次请求，操作身份与 attempt 一致，只有一个逻辑用户问题，来源与持久终态一致，重启不重发。没有调用付费或真实外部模型，没有验收 ASR 或人工听辨音频质量。
- `node Tests/Support/chat-renderer-core.test.cjs` 14 项通过；`uv run Tools/ChatRenderer/prepare-vendor.py` 验证 32 份固定渲染资源及 Avatar 独立生成检查通过；`git diff --check` 通过。

最终证据（本机 ignored 输出）：

| 检查 | 路径（相对工作区） |
| --- | --- |
| 3 项首页/输入导航 UI | `tmp_agent_output/iphone-agent-ui/navigation-4.xcresult` |
| 首页 Avatar 实际像素图 | `tmp_agent_output/iphone-agent-ui/navigation-4-attachments/DF4FDB58-DCD7-4D3C-AC7A-0949EAE7EC06.png` |
| 首点软件键盘图 | `tmp_agent_output/iphone-agent-ui/navigation-4-attachments/730AD5CF-ACCD-4CFE-ACAF-8399D449AA0B.png` |
| 14 项原生渲染测试 | `tmp_agent_output/iphone-agent-ui/renderer-final.xcresult` |
| 完整受控流式 UI | `tmp_agent_output/iphone-agent-ui/stream-journey.xcresult` |
| 独立请求/持久状态检查 | `tmp_agent_output/iphone-agent-ui/ledger-verification.json` |

构建过程中遇到独立工作区缺少 ignored 测试音频，以及目录符号链接被安装器拒绝。已在本工作区复制真实测试音频解决，没有改构建配置。一次包含多个 test target 的 Xcode 运行在目标切换时无进展，已停止该次进程并拆开验证；保留日志，不计为通过。

当前没有将这份侧聊分支安装到用户手机或手表。模拟器验证与物理设备验收分别记录。

## Claude 手机聊天前端优化

用户随后反馈：手机聊天长时间停在“思考中”、工具展示混乱，重新进入 App 时首页与旧会话交替出现；要求先完善前端，直接检查 Claude.ai 的 bundle，复制与重新生成图标也按 Claude 的尺寸调整。本轮从 `origin/main` 的 `dd703be` 建立 `codex/mobile-chat-diagnosis`，保留主目录的未提交修改。

### 当前资源与采用内容

重新打开已登录的 Claude 手机网页，下载其入口、共享模块与样式，共 15 个资源，并保存来源、大小和 SHA-256。主要资源如下：

| 资源 | SHA-256 | 对应实现 |
| --- | --- | --- |
| `index-Bi02dm9l.js` | `670a73e4fd98123b30769007de6f38c2e53c94d181e4fd0bc6ebe480a769e178` | 本轮实际入口及其共享模块依赖 |
| `shared-m-1-CG9OTp1A.js` | `d80f892acfae86ff21006ea77ca9fd4df732c40ccd4b1a47eda2c74f8c68189d` | `D7` 的等待、工具执行、正文生成与空闲状态划分；按调用 ID 关联工具结果 |
| `shared-m-2-DddI6DoO.js` | `34a795400ae821651895e353a76619c6572919e926db859638d1a0f5af6530be` | 编辑区及 visualViewport 的键盘状态处理，原生界面继续由 SwiftUI 管理键盘安全区 |
| `c6a992d55-DneHncv1.css` | `34fee1baed3963a93f841dfc30468c5b0c1cdd456c7a03ad96cabe765e0f05b5` | 输入区结构、正文排版和轻量操作控件 |

复制和重试按钮的实际图形均为 16×16 px，网页按钮为 24×24 px。本项目采用相同图形尺寸，保留 iPhone 的 44×44 px 点击区域。原始资源、DOM 测量与浏览器截图位于被忽略的 `tmp_agent_output/20261016-claude-frontend/references/`。

### 修改后的行为

- 返回用户进入 App 后，先完成资料与所选会话恢复，再显示聊天。恢复期间有独立状态和失败重试入口，不将尚未加载的消息数组解释为空首页。
- `AssistantModel` 将回复执行与本地会话加载分开。创建空聊天不再短暂显示生成中的会话，也不把本地加载显示成“停止回复”。
- 编辑区采用正文输入和底部操作两行结构。输入控件保持原有身份，继续支持生成期间编辑下一条草稿。
- 前端按当前回复区分等待内容、实际思考、工具执行和正文生成；旧轮次工具不会影响当前回复。等待超过 10 秒显示经过时间，收到正文后立即更新 DOM。
- 重试重新订阅时，不将上一轮失败快照写回当前错误提示。当前提交继续负责自己的失败，成功后不会留下旧错误横幅。
- 删除正文渲染的独立定时推进循环，保留 Markdown 增量节点、选择文本保护、阅读位置和停止后已有内容。
- 思考和工具是同级内容。工具按调用 ID 保留节点与展开状态，显示自己的进度和结果；录音检索与原文读取显示返回数量和原文，而不是请求 JSON。
- 统一整理聊天 CSS，移除重复覆盖。同步原生首帧气泡和网页气泡的宽度与圆角；复制与重新生成图形改为 16 px。内容没有超出当前视口时不显示“回到最新消息”。
- 用户补充要求思考文字有 shimmer、Avatar 动效更明显，并将主题与设计之外的聊天交互继续按 Claude 实现对齐。采用当前 CSS bundle 的 `shimmertext` 节奏：2.25 秒循环，在 65% 完成文字扫光；颜色使用本产品的中性色。
- 等待、实际思考和工具执行共用一个 Avatar 实例，依次出现在等待行、思考标题或当前工具旁。转头范围由约左右 8 度扩大至约左右 20 度，并增强倾斜、视线与眨眼；首页静息动作保留。每轮快照不重建或重新播放；进入正文生成且无工具运行时停止，完成、取消、后台和减少动态效果时也停止。

### 本轮验证

验证证据位于本工作区的 `tmp_agent_output/20261016-claude-frontend/`。使用一台专用 iPhone 17 Pro / iOS 27 模拟器，按系统默认字号验证。

- 最终 17 项前端规则检查通过，覆盖当前轮次的状态切换、旧工具隔离、精确保留原文和异常工具结果。32 份离线渲染资源与 Avatar 生成检查通过。
- `native-final.xcresult` 中 39 项草稿与会话测试、17 项原生 WebKit 测试全部通过，0 失败。包括直接呈现流式正文、独立工具卡片、保留展开状态、引用桥接、16 px 图形与 44 px 点击范围、暗色、减少动态效果及阅读位置。
- `chat-ui.xcresult` 中 7 项完整 UI 用例通过：软件键盘首点、导航后编辑、抽屉新聊天保留草稿，以及首包前取消、断流重试与引用、并行会话、停止/重新生成/503/显式重试/回听/重启。独立只读账本核对四个场景分别为 1、2、2、4 次请求，重启无重发，取消与会话身份一致。
- 上述 UI 用例通过后，截图复核发现成功重试仍显示旧错误。补上错误提示断言并修复旧失败快照回写后，`retry-ui-final.xcresult` 的两项定向旅程全部通过：断流后重试与来源过期，以及停止/重新生成/503/重试/回听/重启。成功后及重启后均无旧错误提示；这两项是针对最终修复的复验，不与此前 7 项合称一次 9 项运行。
- 最终构建的 `chat.js`、`chat-core.js`、`chat.css` 和 `index.html` 与当前源码 SHA-256 逐一相同，核对结果为 `built-renderer-verification.json`。
- 初次原生测试中的两个失败来自旧外层工具 disclosure 的断言，已按新层级更新；另一次截图检查将稀疏的等待画面误报为空图，实际截图包含原文字和 Avatar，采样由 32×32 改为 128×128 后复验通过。保留首轮日志，不将其记作通过。

本轮构建为 build 4，尚未覆盖安装到用户的物理手机或手表。受控流式旅程使用真实 App、Pi、URLSession 和 WebKit，输入为合成 SSE；它验证前端与桥接行为，不提供用户当前 OpenRouter 请求的实际分块时序。

合入前，远端 main 新增 `0343805` 的聊天/转录底部导航。本分支保留新的 `TabView`、两个独立导航栈和切页时收起键盘的处理，将本轮恢复状态放在首次体验与标签页入口之外。组合提交 `0d5ac15` 的 `native-main-integration.xcresult` 56 项原生测试和 `ui-main-integration.xcresult` 8 项 UI 测试全部通过；包括底部导航、生成中切页后返回原会话及独立草稿。

补上 shimmer 与 Avatar 增强后，`native-motion-final.xcresult` 的 56 项原生测试全部通过。真实 WKWebView 检查了等待、思考、工具阶段的同一 Avatar 节点和实际几何变化、文字扫光、后台暂停及减少动态效果下的静态可读文字。7 项 Avatar 时钟测试通过；32 份渲染资源和 24 份固定 Avatar 源码验证通过。最终构建的四个渲染文件及 Avatar bundle 与当前源码的 SHA-256 一致，记录在 `built-renderer-verification.json`。

最终代码提交 `548d462` 的 `ui-motion-reviewed.xcresult` 中 8 项 UI 用例全部通过，0 失败：4 项受控聊天旅程及 4 项输入与导航检查。`motion-final-ledger-verification.json` 独立核对四个场景的 1、2、2、4 次请求、操作 ID、重试 attempt、持久化终态和重启无重发；各场景的 SQLite `quick_check` 均为 `ok`。首轮 `ui-motion-final.xcresult` 在首个场景的 App 退出步骤停止推进，测试管理日志确认 App 已退出，随后中止运行并重启本任务专用模拟器；该轮不计为通过，原日志保留。

最终实际截图已经复核：`ui-motion-reviewed-attachments/EF73AEBE-44A6-4C18-B21B-5985015C9AE7.png` 为重试完成与来源引用，`FFE35C60-69AE-4A38-BEC7-212EE82F6C05.png` 为首页首次点按后的软件键盘，`6D71DD26-FC79-47CC-8DEB-0F3E44DC4EBE.png` 为底部聊天入口；均位于上述证据目录。思考和工具阶段截图在 `native-motion-final-attachments/`。

手机诊断另确认两次模型请求为 TLS 握手失败，`NSURLErrorDomain -1200`，没有收到正文。正常模型配置使用系统代理默认值；本轮前端修改不改变网络路由，也不把界面改动登记为这两次传输错误已修复。
