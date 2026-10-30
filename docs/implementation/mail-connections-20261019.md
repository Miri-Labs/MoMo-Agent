# 邮件与渐进式连接授权

> Gmail 当前流程以[用户自备客户端配置](gmail-user-setup-20261019.md)为准：onboarding 跳过，设置内配置，下面关于内置 client ID 和直接开关授权的说明保留为历史记录。

功能基线：`74ca8dc`，功能提交：`69e0f3c`。合并时同步最新 main，保留聊天后台任务与录音处理更新。源码版本：1.9.0，内部构建号 46。本次不安装到真机。

## 界面

首次体验结束后显示真实的连接页，也可跳过演示直接进入。保留原品牌图标与 MoMo。

- 首屏只有邮件、健康、日历、提醒事项四行，每行包含名称、一行用途、开关。
- 点名称查看详情。健康的具体范围和 AI 数据使用说明在次级页面展开，确认后才请求 HealthKit 权限。
- 打开邮件入口或打开邮件开关后，先显示二级邮件配置页。本版只有 Gmail，兼容 Google Workspace；开启其中的 Gmail 开关才打开系统浏览器完成授权。取消、拒绝或校验失败时保持关闭，验证账号后才显示邮箱地址。
- 邮件的“使用范围”默认收起，点开后才显示数据使用说明。账号已连接时提供 Google 授权管理入口；首屏的邮件开关可直接断开。
- 日历与提醒事项只有一个可写位置时直接连接；多个位置时才展开选择页。
- 闹钟、地点及其他系统管理入口放在“更多连接”。所有连接都可以跳过，之后从设置的“连接与权限”修改。

健康开关保存的是允许 MoMo 使用健康摘要的选择。HealthKit 不提供逐项读取授权状态，因此不能把授权页完成、没有返回数据或开关开启解释成“所有健康项目均已授权”。

## 健康数据

在现有睡眠、步数、活动能量和训练读取中加入心率、静息心率。通过 HealthKit 每日统计查询读取已有记录，不启动持续心率测量。心率返回样本平均、最低和最高值；静息心率返回日均值。没有记录的项目保持未知，不能填零，也不能推断疾病、压力或情绪。新字段可读取旧版没有心率字段的健康快照。

## 邮件能力

本版只接 Gmail，以原生 OAuth 与 Gmail API 完成发送和回复。邮件能力独立于界面和 Agent 工具，之后可以在二级页面增加其他连接。本版不引入多提供方目录、MCP 客户端、邮件网关或 IMAP／SMTP。普通用户不填写开发配置。

工具：`get_mail_connection`、`search_mail`、`read_mail_thread`、`create_mail_draft`、`send_mail`、`reply_mail`。

- 授权码 + PKCE + state，通过 `ASWebAuthenticationSession` 登录；校验回调、实际授予的 scope 和邮箱 profile。原生客户端不包含 client secret。
- 访问与刷新凭证只保存到独立的邮件 Keychain 服务，工具和模型均拿不到凭证。刷新请求合并，断开优先于迟到的登录回调。
- 仅按当前任务检索邮件。正文是第三方资料，不能授予发送权限。撰写或保存草稿不会自动发送；发送与回复需要当前用户明确指令。
- 回复重新读取原邮件，使用 Reply-To / From、原主题、threadId、In-Reply-To、References，模型不能覆盖收件人。支持中文主题、UTF-8 MIME 与编码主题，拒绝头部注入和含糊的多地址回复目标。
- 草稿和发送在网络请求前写入持久回执记录。相同用户请求恢复时复用结果；超时或异常中断后保留“结果待核对”，不自动重发。每个用户请求最多发送一封邮件。
- 已标记使用邮件的会话在断开或换账号后，会过滤较早的模型对话输入并停止历史压缩；同一轮操作中换账号会取消该轮外发。原会话保留供用户阅读。

当前不包含自动巡检收件箱、附件发送、回复全部收件人或其他邮箱提供方。

## 应用注册：交付前必需

2026-10-19 已补齐 MoMoAgent 的真实 Google iOS OAuth 客户端与反向回调，默认值随 `Config/App.xcconfig` 分发。Google 侧状态及验证见 [Gmail OAuth 配置](gmail-oauth-configuration-20261019.md)。下列步骤供以后更换客户端时使用。

1. 在应用所属 Google Cloud 项目启用 Gmail API，配置 OAuth 同意屏幕。
2. 创建 iOS OAuth 客户端，Bundle ID 为 `com.momoagent.ios`。测试阶段将测试邮箱加入测试用户；公开使用按 Google 控制台要求完成验证。
3. 在 `Config/App.xcconfig` 同时更新两个公开值，替换下方示例。`Config/Local.xcconfig` 只用于临时本机覆盖；分发默认值必须保留在共享配置。不填写 client secret：

```xcconfig
MOMO_GOOGLE_CLIENT_ID = 123-example.apps.googleusercontent.com
MOMO_GOOGLE_CALLBACK_SCHEME = com.googleusercontent.apps.123-example
```

4. 使用 XcodeGen 2.46.0 重新生成工程。回调 scheme 必须与客户端 ID 的反向域名一致。
5. 用测试邮箱实际授权，验证保存草稿；由用户明确授权后再验证发送、回复与 Google 侧撤销授权。

申请的权限为 `gmail.readonly` 与 `gmail.compose`。应用不要求删除邮件或修改标签的权限。

## 验证

邮件与权限逻辑测试使用固定 HTTP 响应，不代表实际 Gmail 授权或发送已经验证。合并清理后，日志和截图归档到 Mizzen 工作区的 `tmp_agent_output/20261019-mail-onboarding-merged/`，不随代码提交。

真实的 Agent 源码、归档依赖和原生连接页面单独组成验证目标，避免构建、安装或改动主线程的转录与手表产物。完整产品的真机安装与 Gmail 实际授权不在此次验证结果内。

- 17 项邮件、会话权限与健康摘要测试通过。覆盖 PKCE 与回调校验、权限不足、迟到回调、刷新合并、草稿不发送、持久回执去重、超时不重发、回复来源校验、MIME 注入防护、断开后的上下文过滤，以及心率字段兼容。
- 合并最新 main 后重跑 17 项测试通过；额外在邮件会话中验证超过 12 次模型请求仍可继续，断开或换账号仍会阻止旧权限继续使用。
- 实际 MoMoAgent 源码与连接页面的 iOS 类型检查通过，原生组件验证目标构建通过。
- 默认字号下验证浅色与深色界面。连接项初始关闭，邮件二级页不自动请求授权，未配置 Gmail 时保持关闭；健康范围按需披露，取消后保持关闭，开始使用不依赖这些连接。
- `git diff --check`、前端脚本语法与 Info.plist 格式检查通过。

## 一手资料

- [Google 原生应用 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Gmail 创建与发送邮件](https://developers.google.com/workspace/gmail/api/guides/sending)
- [Gmail MCP 接入与工具列表](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server)
