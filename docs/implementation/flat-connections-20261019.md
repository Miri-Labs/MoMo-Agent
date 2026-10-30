# 单页连接与 onboarding

> Gmail 当前流程以[用户自备客户端配置](gmail-user-setup-20261019.md)为准：onboarding 跳过，设置内配置，下面关于内置 client ID 和直接开关授权的说明保留为历史记录。

基线 `a0f1acc`，任务分支 `fix/flat-connections`。配置版本 1.9.2，内部构建号 48。本次不生成、安装或交付 App 二进制。

## 行为

- 设置与 onboarding 共用 `PhoneConnectionOptions`，同页展示 Gmail、健康、日历、提醒事项、闹钟、到访地点。
- 删除邮件详情、更多连接、系统与健康、生活信息等中转页和重复说明；连接名称不再承担隐蔽的详情导航。
- Gmail 开关直接发起系统 OAuth，关闭直接断开。取消授权保持关闭，失败在当前行显示，可重试。普通用户无需填写开发者配置。
- 日历和提醒事项：点击开启后请求系统权限；只有一个可写位置时直接连接，多个位置在原行展开，点击位置即完成连接。取消选择不启用连接；已连接位置也在原行修改，取消编辑保留连接。原有默认位置与偏好继续使用，不迁移或清空数据。
- 闹钟直接请求系统权限并连接，无额外确认页。仅管理 MoMo 创建的闹钟。
- 健康、日程对话和地点的首次启用保留简短数据用途提示；取消不打开权限。原有日程上下文偏好、后台定位、地点清空及存储失败处理继续可用。打开页面不触发系统授权，也不读取健康明细。
- 健康摘要和行动记录只在设置中保留为结果查看入口，onboarding 只呈现连接控件。

## Gmail 配置

后续已于 2026-10-19 创建真实 iOS OAuth 客户端，填入共享构建配置，并在 Google Cloud 启用 Gmail API、保存权限和测试用户。当前为 Testing 状态，尚未安装或验收真机授权。详见 [Gmail OAuth 配置](gmail-oauth-configuration-20261019.md)。以下记录单页连接任务完成时的缺口。

仓库 `MOMO_GOOGLE_CLIENT_ID` 仍为空，默认回调 scheme 也不是一个已注册 Google 客户端的反向域名。仅修改按钮无法让 Google 接受登录。已向用户请求应用自己的公开 iOS client ID；本任务环境没有 Google Cloud 项目身份，不能编造客户端或复用其他应用的注册。

取得 Bundle ID 为 `com.momoagent.ios` 的真实 iOS OAuth client ID 后，需要将公开 ID 和反向 callback scheme 一起写入构建使用的配置，并确认所属项目已启用 Gmail API、测试用户/发布状态正确。例如 client `123-xyz.apps.googleusercontent.com` 对应 `com.googleusercontent.apps.123-xyz`，此处仅为格式示例，不是可用配置。不要填写 client secret。

`verify-release-bundle.py` 新增两项必需校验：真实包内 client ID 的格式，以及其准确反向回调是否注册。缺少或占位配置不能再通过发布验收。此检查只证明配置结构完整，不证明 Google 侧注册、账号授权或实际 API 请求成功。

## 验证

- Gmail 发布配置的 2 项独立 Python 用例通过：拒绝缺失、占位、格式错误的 client ID，拒绝缺失、格式错误或不匹配的回调，接受准确反向回调。
- 修改的 6 个 Swift 文件经 Tree-sitter Swift 语法解析通过；这不是 Swift 编译或 SwiftUI 类型检查。
- Info.plist、工程引用完整性及 `git diff --check` 单独检查。
- UI 回归同步为单页操作，覆盖 onboarding 可跳过、健康提示取消、Gmail 直接反馈、日历/提醒位置选择与断开持久化、闹钟直接授权。
- 当前 Linux 环境没有 Swift/Xcode，未运行 iOS 构建、模拟器、UI 回归或完整 Release 包验收。现有 GitHub Actions 在基线提交即因账户账单/额度限制未启动任务（run `39206142036`，check `117909290513`），不能借 CI 完成这些检查。
- 本次单页连接任务未验收 Gmail 真实登录、账号切换、保存草稿、发送与回复；后续已补齐 client ID，真机授权仍待验收。
