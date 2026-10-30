# Gmail 用户自备客户端

基线 `origin/main` 的 `971389d`。按用户要求，使用者自行创建 Google OAuth 客户端；onboarding 暂时跳过 Gmail。配置版本 1.10.0，本次不交付二进制。

合并 main 时保留当前 1.10.1 版本和内部构建号 50，同时保留原音分块同步与接收回执更新。本次合并不生成或安装 App。

## 使用流程

- Onboarding 保留健康、日历、提醒事项、闹钟和到访地点，提示 Gmail 可稍后在设置中连接。
- 设置 → 连接与权限 → Gmail「配置」打开原生配置页。未填写有效 ID 时不能发起授权。
- 页面内置四步 Google Cloud 实际截图：启用 Gmail API、配置受众与权限、创建 iOS 客户端、复制 ID。截图可以点开放大；权限范围和 Bundle ID 可以复制。图片作为 `GmailSetup` 文件夹原样打包，按文件地址加载，用 UIKit 原生滚动与缩放查看。
- Google 项目由使用者创建并启用 Gmail API。iOS 客户端的 Bundle ID 为 `com.momoagent.ios`。不启用 Firebase App Check 时，App Store ID 和团队 ID 可以留空。AI-powered agent 选项启用；无需 client secret。
- 使用者填写自己客户端的 ID，点「保存并连接 Google」，在系统授权会话登录。仅在权限与账号校验通过后显示已连接。
- client ID 与 OAuth 凭证保存在本机 Keychain，分开存储。取消登录保留 client ID。更换客户端前先断开邮箱；旧 token 不会因重新填写 ID 被启用。
- 使用动态 `ASWebAuthenticationSession.Callback.customScheme` 接收本次授权的反向 client ID 回调，再由运行时校验 PKCE 与 state。不需要把每个使用者的回调 scheme 写入安装包。
- 安装包不再包含共享 client ID；发布校验检查用户配置模式与共享 ID 缺席。更换客户端、读写失败和迟到回调仍由同一个 Mail controller 管理。

## 授权期限与分发

Google Testing 模式下，带 Gmail 范围的 refresh token 七天到期。个人自用可按 Google 的个人使用规则完成品牌资料并切换 In production，再重新连接。授权仍可能被撤销，不能承诺永久有效。Google 授权配置和 Apple 商店上架分别处理；自备客户端不代表已取得公开分发、数据使用或商店审核通过。

邮件内容使用说明保留在连接页。原有发送确认、发送结果不确定时禁止自动重试、凭证隔离与操作账本继续使用。

## 验证

验证记录在本工作树 `tmp_agent_output/20261019-gmail-user-setup/`。邮件协议使用受控 HTTP/浏览器 fixture，原生界面与系统回调用独立验证 App 检查，不启动主线程的手机或手表构建、不安装真机。

- 邮件源码的 14 项测试通过，覆盖配置持久化、切换客户端、残留 token、取消与迟到回调、配置读写失败，以及原有发送与刷新逻辑。
- Release 检查器 23 项自检通过；不等同于完整产品 Release 包验收。
- 独立原生目标编译通过，`FinalUI.xcresult` 的 3 项 UI 检查全部通过：默认字号的浅色/深色配置页、无效 ID、四张教程图片、图片预览打开、双指两倍放大与关闭、退出配置页、无固定 scheme 的动态回调。
- 四张图片在验证包内与源码 SHA-256 一致。`resource-check.json` 同时确认验证 App 未注册固定回调 scheme。`git diff --check` 与 plist 检查通过。
- 完整产品的 onboarding / 导航回归已更新测试代码，本次没有运行完整产品构建或该组 UI 测试。原生目标直接复用本次 Mail 源码、Keychain、页面与授权适配器，只替换验证 App 入口。

真实 Google 账号的完整授权、草稿与发送仍需账号交互验收；本次没有发送邮件。

## 参考

- [Google iOS 授权](https://developers.google.com/identity/sign-in/ios/api-access)
- [Google AI agent 客户端标记](https://support.google.com/cloud/answer/15549257?hl=en#agentic-client)
- [Google 测试模式与受众](https://support.google.com/cloud/answer/15549945?hl=en)
- [Google 个人自用例外](https://support.google.com/cloud/answer/13464323?hl=en)
- [Apple 系统网页授权会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
