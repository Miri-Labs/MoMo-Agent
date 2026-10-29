# Pi 会话存储与资料失效

日期：2026-10-13。范围：手机 Agent 实现，保留已确认的 Pi Agent Kit 与外部模型 API 路线。

PiDurableKit 以上游 [`885ada3f14c17f48da85c3ac8b359e7f81a8b84f`](https://github.com/finnvoor/PiDurableKit/tree/885ada3f14c17f48da85c3ac8b359e7f81a8b84f) 为基线，当前通过 `Vendor/PiDurableKit` 接入可重建的传输补丁。应用直接使用其 `Harness`、Swift `Tool`、`PromptSection`、`Hook`、`Models`、`CustomProvider` 和 SQLite storage，不另写模型与工具循环。补丁决策见 [传输失败与期限](pi-transport-failure.md)。

## 存储与所有权

每个用户对话对应一个 UUID 目录，内有 `pi.sqlite` 和 `session.json`。Pi 独占自己的会话、消息、任务和工具状态。`session.json` 只保存应用会话名称、来源引用、当前请求 ID、请求预算和用户取消状态，不保存转录正文或密钥。

`PiAgentHost` 由 App Runtime 持有。一个路径同一进程只允许一个 owner；并发打开复用同一个 opening task。页面离开只取消 UI 观察，不关闭 harness。运行时主动关闭调用官方 `Harness.close()`；取消调用 `Conversation.abort(background: true)`，取消等待本身不当作取消 Agent。

目前以每个对话单独存储解决资料删除：录音删除或正文修订后，Archive 持久登记待清理会话；Agent 停用其来源、停止任务、等待官方关闭存储，再移除整个对话目录，最后通知 Archive 清理完成。清理期间拒绝恢复、工具调用和模型请求。不直接修改 Pi 内部表，不把 reset 当作删除。此策略会移除一个受影响对话的整段历史；其他对话独立保留。界面必须同时清除已缓存的受影响消息。

## 来源与工具

近期上下文由规则选取：最近 8 次录音目录，最多 3 次录音的近期段落，最多 20 段及 10,000 字节正文。单段超过 1,200 字节时明确标记截断。搜索与分段读取继续提供来源和版本。

正文进入 Pi 前调用 Archive 来源登记。后续模型请求和工具执行都检查会话是否仍有效。工具写计划只接受本会话已读取的来源。`write_plan` 使用用户请求的稳定 UUID，Pi tool memo 保留同一值，Archive 用操作 ID 与内容哈希去重。

注册的工具只有 `get_context_status`、`list_recordings`、`search_transcripts`、`read_transcript`、`play_audio`、`write_plan`。不安装 coding tools，不提供执行环境，不启用 shell、任意路径读写或动态扩展安装。

## 模型 API 与限制

支持用户配置的 HTTPS OpenAI Completions、OpenAI Responses、Anthropic Messages 协议。base URL 不接受内嵌用户名、密码、query 或 fragment。凭据按协议和目标 URL 的哈希隔离，保存在 `MoMoAgent.ModelCredentials` Keychain service；普通设置文件不保存密钥。仅注册当前用户选择的 provider，关闭默认 providers，模型输入限定文本。

初版预设阿里云百炼北京按量付费，模型为 `qwen-plus`。`compatibility: .bailianBeijing` 只使用 Chat Completions，支持共享域名与业务空间专属域名。Pi 模型声明 `reasoning: true` 和 `thinkingFormat: qwen`，会话设置 `thinkingLevel: off`，这样 Pi 才会在 HTTP 请求中显式写入 `enable_thinking: false`。配置细节与真实 API 验证入口见 [百炼验证记录](../implementation/bailian-validation.md)。

URLSession 使用 ephemeral 配置，关闭 cookies 和缓存。传输补丁分别限制响应头等待 30 秒、正文首字节 45 秒、正文空闲 30 秒；一轮最多发出 2 次 HTTP 请求，关闭额外 durable retry。单个用户请求最多 12 次模型请求、总等待期限 120 秒，各轮共享剩余期限。401 / 403 不自动重试；429 按有效 Retry-After 等待，超出预算时保存允许重试时间。以上是配置与实现要求，实际时序验收见实施记录。关闭自动压缩；长会话仍受 provider 上下文窗口限制。

## 已验证与待验证

- SDK 26 的 CLT 对原版 Pi 编译失败：`FoundationModelsProvider.swift` 引用了 SDK 27 才有的 `LanguageModel` 等类型。部署版本的 `@available` 不能解决编译 SDK 缺少类型。
- 2026-10-13 的临时验证副本仅排除了本地模型适配文件，其他源码、JS 和资源不改；该副本 macOS build 通过。这是当时 CLT 的验证记录。现已安装 Xcode 27，后续正式构建与传输补丁验收以实施记录为准。
- 临时宿主已执行真实 Pi JS harness、真实 SQLite 与真实 Archive 的集成验证。模型回复由官方 FauxProvider 脚本提供：自动上下文、搜索、保存带来源计划、重复请求、关闭重开、资料修订导致会话失效、整库清理共 12 项断言通过。这是软件集成证据，不是外部模型 API 或 iPhone 验收。
- 正式 Swift Testing 用例在 `MoMoAgentTests`。百炼真实 API 用例需要 `MOMO_E2E_API_KEY`，地址与模型默认北京共享域名及 `qwen-plus`。用例同时检查独立 Keychain service 的读写与重开，结束后移除测试凭据。没有凭据时用例跳过；跳过不计入真实 API 通过。
- Watch 到手前，Watch 后台录音、腕部音质、真实配对传输和 18 小时续航仍不能验收。
