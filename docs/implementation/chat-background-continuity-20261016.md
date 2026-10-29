# 聊天顶部背景统一

用户指出 MoMo 页头与聊天正文存在灰白分层。本轮从 `origin/main` 的 `849f023` 建立任务分支。

旧截图为 1206×2622 px，在 y=493 处，背景从页头的 `#FFFFFF` 变为正文的 `#FAFAFA`。原因是自定义页头使用 `MoMoPalette.paper`，页面与 WebKit 正文使用 canvas 对应的颜色。深色模式下，两者也分别为 `#202020` 与 `#161616`。

将 `AssistantView.assistantHeader` 的背景改为 `MoMoPalette.canvas`，与页面背景共用颜色资源。

验证使用本任务专用 iPhone 17 Pro / iOS 27 模拟器、系统默认字号，证据位于本 worktree 的 `tmp_agent_output/20261016-chat-background/`：

- `build.log`：`build-for-testing` 通过，编译路径为本任务 worktree。
- `chat-light.xcresult`：现有停止、重新生成、503 重试、引用回听和重启恢复的 UI 旅程通过，同时检查实际头像像素与 MoMo 名字。
- 浅色完成会话截图：`chat-light-attachments/2A8ACA5A-50AA-4B38-9145-F22D075859C2.png`。
- 深色完成会话截图：`chat-dark.png`，由同一安装包恢复同一受控会话后采集。
- `background-pixel-verification.json`：状态栏空白、页头与正文采样均为浅色 `#FAFAFA`、深色 `#161616`。额外检查 y=490、492、493、494、496、500 六行，每行全部 1206 个像素颜色一致，原边界无颜色跳变。

已目视复核两种外观的实际截图。未在物理手机安装本轮构建。
