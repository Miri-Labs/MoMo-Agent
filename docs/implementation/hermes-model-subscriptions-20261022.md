# Mac 订阅接入与窗口（1.24.0）

用户要求去掉独立的窗口标题栏，并将模型接入按 Codex 订阅、Claude 订阅、API 排序。同时清理已结束任务的缓存和旧编译产物。

## 界面与状态

采用 standard 配置：保留系统窗口按钮和窗口行为，隐藏独立标题文字，窗口内容延伸到顶部，顶部静态区域支持原生窗口拖动。相比整页列出三个表单、三个大卡片的结构，最终使用原生分段选择器；每次只显示当前服务所需信息。默认选择 Codex，API 的三项输入仅在第三项出现。品牌仍用原字标，其他文字使用系统字体。

`DesktopModel` 继续拥有跨页面状态，onboarding 和设置复用同一个接入表单。选择项、登录状态、检查状态、验证失败、浏览器登录等待和取消都有对应显示；验证时冻结输入，避免验证一个模型后保存另一个模型的竞态。取消会终止本轮认证进程，Claude Code 子进程及其回调监听也随之终止。停止当前 Agent 后才允许替换运行配置。

## 复用 Hermes

`Apps/MacApp/Runtime/model_setup.py` 运行于应用已准备的隔离环境：

- Codex：复用 `hermes_cli.auth_codex_browser` 的浏览器 PKCE 登录及 Hermes 私有凭据存储；刷新和模型目录仍使用 Hermes。状态检查只读，不自动导入 Codex CLI 的可轮换 refresh token。
- Claude：调用本机官方 `claude auth login --claudeai`，随后使用 Hermes 的 Claude Code 凭据发现、刷新与 Anthropic adapter。Claude 订阅入口拒绝静默使用 API key，不另建一个第三方 Claude 网页授权端点。
- 订阅验证：使用已有 SDK 和 Hermes 的请求头、OAuth / Messages 转换发送一条不含个人资料的短测试消息；成功后原子保存 provider 和 model，丢弃旧 custom API 地址。验证失败不改变原订阅/模型配置，也不启动新 Agent。
- Python 给 Swift 的结果只有登录标记、模型目录和固定错误文案。token、SDK 原始错误、OAuth URL 和账号元数据不传入 Swift 或手机；诊断保存在私有本机日志。
- API 接入继续使用已有验证流程；请求前校验密钥格式。

网络层与手机协议均未接入供应商认证逻辑。Access / WebRTC 只承载原有应用协议；供应商凭据留在 Mac Agent 侧。

参考的官方认证说明：[Codex](https://developers.openai.com/codex/auth/)、[Claude Code](https://code.claude.com/docs/en/authentication)。本实现依照仓库固定的 Hermes 代码装配；第三方服务的实际订阅额度、可用模型及登录授权仍由账号决定。

## 验证

- Mac Beta 构建及本机安装、启动通过；主窗口已移除独立标题栏。
- 认证配置 10 项测试与既有运行环境 7 项测试通过，覆盖验证失败保留配置、旧 API 地址移除、API key 与订阅隔离、Codex 不自动借用外部 refresh token、Claude 官方命令与 stdout 隔离、取消/超时清理子进程、SDK 错误脱敏。
- 使用实际隔离运行环境检查 Codex 状态与 Hermes Anthropic 请求装配；没有读取或输出真实 token，也没有代替用户完成浏览器授权。
- 原生 UI 检查三种入口、空 API 表单失败、设置表单和系统默认字号。实际窗口截图通过电脑操作检查，安装包报告保存在当前任务 outputs。
- 尚未以实际 Codex / Claude 账号完成浏览器登录和真实推理，不能把单元测试当作账号订阅验证。
- iPhone / Watch 当前不可连接，不声称已在真机安装或验证同步。

## 清理

已清理此前 159 个临时构建/测试项目，约 14.26 GiB 逻辑占用。新安装包验收后又清理本轮 DerivedData、SPM 临时构建目录（约 4.21 GiB 逻辑占用）、61 个 Python 缓存目录与被替换的旧 Beta 安装包；保留已安装 app、私有运行环境、源码、固定 XcodeGen 工具及最新交付证据。

当前外观仍沿用项目原有明亮主题；没有宣称深色外观已验收。尺寸缩放、Tab 在 API 输入间移动和设置页复用已在实际窗口确认。未以实际账号完成授权，因此不对完整登录体验给出已验收的评分。
