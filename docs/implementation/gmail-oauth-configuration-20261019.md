# Gmail OAuth 配置

> 后续已按用户要求改为[用户自备客户端](gmail-user-setup-20261019.md)。安装包不再内置本页的共享 client ID；下面保留 Google Cloud 创建与验证的历史记录。

2026-10-19，基线 `971389d`。真实 Google iOS OAuth 客户端和回调已写入 `Config/App.xcconfig`，供 Debug、Release 共用；现有 Info.plist 和生成工程已经引用这两个构建变量，无需修改授权代码或重新生成工程。本次保持现有版本，不生成或安装 App。

## Google Cloud

- 项目：`momoagent-personal-20261019`，显示名称 MoMoAgent。
- Gmail API：`gmail.googleapis.com`，控制台确认已启用。
- 客户端：MoMoAgent iOS，类型 iOS，Bundle ID `com.momoagent.ios`，Apple Team ID `3WRUNH54B3`。
- 客户端已标记为 AI Agent，供 MoMo 邮件工具使用。没有启用代码尚未接入的 Firebase App Check，也没有创建客户端密钥。
- 同意页名称 MoMoAgent，用户类型 External，发布状态 Testing。当前登录的 Gmail 账号已加入测试用户列表。
- 声明范围仅为 `https://www.googleapis.com/auth/gmail.readonly`、`https://www.googleapis.com/auth/gmail.compose`，与应用现有请求一致。控制台确认已保存。

公开 client ID 与反向回调统一保存在 `Config/App.xcconfig`。账号 access token、refresh token 由现有 Keychain 流程保存，不写入仓库。

## 验证与后续使用

- 既有 Gmail 发布配置两项用例通过。
- 将实际配置代入源码 Info.plist，发布检查器的 `gmail_oauth_configured`、`gmail_callback_registered` 均为 true。这是源码配置验证，没有生成或检查实际分发包。
- Info.plist 格式及 `git diff --check` 通过。
- Google 控制台确认客户端创建、测试用户保存、两项范围保存与 Gmail API 启用。
- 手机仍需安装包含此配置的新版本，并由用户在 App 内完成 Google 同意授权。本次没有读取邮件、创建草稿或发送邮件，尚未验收真机登录和邮件 API。

Testing 状态只允许列出的测试用户。Google 对包含 Gmail 权限的测试授权和 refresh token 设置七天有效期，届时需重新连接；对外分发前另行完成品牌信息、发布状态与所需验证。

## 参考

- [Google iOS API 授权与反向回调](https://developers.google.com/identity/sign-in/ios/api-access)
- [Google AI Agent 客户端标记](https://support.google.com/cloud/answer/15549257?hl=en#agentic-client)
- [Google 测试用户与授权有效期](https://support.google.com/cloud/answer/15549945?hl=en)
