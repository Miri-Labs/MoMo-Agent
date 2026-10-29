# 独立会话运行与单层思考区

## 问题与行为

原来的 `PhoneRuntime` 只持有一个 `AssistantModel`，生成期间又禁用新聊天。页面选择、草稿与生成任务由同一个实例持有，导致一个会话等待模型时，用户无法开始另一个会话。

新增运行时持有的 `AssistantConversations`，按会话保留原来的模型实例。切换只改变当前查看的模型，生成、取消、失败与重试仍归各自的 `AssistantModel` 管理，不引入第二套请求状态机。A 生成时可以打开 B，B 可以先完成；A 的完成或失败不会把页面切回 A，停止 A 也不会停止 B。侧栏对正在回复的会话显示小型进度指示。

输入草稿、选中来源与阅读位置分别保存。无会话 ID 的首页草稿在切换历史之前先建立自己的空会话，保留来源但不发送；若创建失败，留在原页显示错误，不隐藏草稿。切换时到达的旧网页滚动回调根据其会话 ID 路由，不写入新页面。后台洞察仍等所有交互会话结束后再运行。

截图中的双层“思考过程”来自外层过程 disclosure 和每条 reasoning 自带的第二个 disclosure。现在 reasoning 是外层展开后的正文，无重复标题、头像与边框；工具步骤保留各自的请求/结果明细。流式增量更新保留用户的展开或折叠选择。

## 本地状态兼容

- 原 `assistant-presentation.json` 仍由第一个会话使用，不迁移或覆盖旧格式。
- `assistant-conversations.json` 仅索引当前选择与各会话的展示文件；其余展示文件位于 `assistant-conversations/<UUID>.json`，继续使用原展示状态格式。
- 索引验证版本、大小、记录身份与会话身份唯一性；损坏时保留原文件并显示保存受限提示。展示状态与索引分别原子写入。
- 重启只恢复本地记录和草稿，不自动发送、重试，也不承诺 iOS 进程被终止后仍持续联网生成。

## 参考

延续 [Avatar 与对话输入修复的实际源码检查](iphone-agent-ui-20261016.md)：Claude 的临时/持久消息身份、流式终态和稳定编辑器，以及 Chatbox、RikkaHub、PocketPal AI 的状态所有权与取消处理。Chatbox 的流式缓存按 `sessionId + messageId` 定位；PocketPal 的消息更新带所属 `sessionId`。本轮将同样的归属原则落实到现有 SwiftUI/Pi 运行时；没有照搬另一套 UI 或引入其依赖。

## 验证

专用 iPhone 16 / iOS 27 模拟器，系统默认字号，只运行一台模拟器。外部服务由隔离的合成 provider/SSE 替代，不调用用户或付费模型。

- 39 项草稿/模型集成测试与 15 项原生 WK 渲染测试通过，0 失败。覆盖真实 Pi 并行请求、取消隔离、后台失败和重试隔离、旧状态恢复、独立来源/草稿/阅读位置、损坏索引保留原字节、保存失败时留在原草稿，以及一次展开后流式更新保持选择。
- 多会话完整界面用例通过：A 保持流式时新建 B，B 独立完成；侧栏显示 A 仍在回复；分别保留下一条草稿；停止 A 后切回 B；重启后恢复 B，再切到 A 核对其独立草稿。只读检查实际请求账本、索引和展示文件共 15 项通过：两个不同 session/operation，B 完成早于 A 取消，重启请求数仍为 2，终态分别为 cancelled / finished。
- 停止→重新生成→503→显式重试→inline 引用回听→重启恢复的既有 UI 用例通过；独立只读账本核验通过，无自动重发。
- 3 项原生导航/输入 UI 用例通过：角色实际像素、首点软件键盘、导航往返继续编辑、菜单新聊天保留草稿。上述 UI 分两轮执行，不合称一次完整测试运行；第一轮新多会话测试误将占位文本当作空输入值，修正为检查空字符串后完整通过。
- `chat-renderer-core.test.cjs` 14 项通过，固定离线渲染资源与 Avatar 生成检查通过。

本轮不操作用户手机或手表；此前 main 的 Watch 波形和录音读取修复保留。

本机证据均在本工作区被忽略的 `tmp_agent_output/parallel-chats-20261016/`：`model-renderer-reviewed.xcresult`、`parallel-ui-2.xcresult`、`ui-1.xcresult`（既有流式与 3 项导航用例）、`stream-ledger-verification.json`、`parallel-ledger-verification.json`。实际单层思考区截图位于 `reasoning-preview/8AA42E77-06D6-467A-A809-2A3A3A904BE8.png`。
