# MoMo Agent 上架隐私与审核材料

准备日期：2026-10-15。范围：基于生产代码的文档准备，不修改 App、不提交 App Store 审核，不代替主管部门备案确认。

2026-10-27 仅同步产品名为 MoMo Agent。这组草稿仍描述准备时的手机本地 Agent 架构，发布前须按当前 Mac Hermes、资料来源与通知实现重新核对。

## 文件

- [中文隐私政策草案](privacy-policy.zh-CN.md)
- [English privacy policy draft](privacy-policy.en.md)
- [中英文审核说明及发布条件](app-review-notes.md)

政策尚缺实际运营主体、隐私联系邮箱及生效日期。审核说明尚缺联系人、公开 URL、最终版本、审核专用配置及设备演示。补齐这些字段并解决审核说明中的发布阻塞项后，才可作为正式提交材料。政策是根据当前实现起草的实用草案，不构成法律意见。

## 代码证据与表述边界

以下路径均相对仓库根目录；不以历史截图或旧测试结果证明本次状态。

| 事实 | 代码证据 |
| --- | --- |
| “AI 服务”支持保存多个连接；未配置时不预选服务商或模型；预设只填地址与协议，读取模型后由用户选择／填写模型并验证使用 | `Apps/iPhoneApp/Features/Settings/ProviderSettingsView.swift`；`Apps/iPhoneApp/Features/Settings/ProviderSettingsModel.swift`；`Packages/MoMoAgentKit/Sources/MoMoAgent/Providers/ProviderConnections.swift` |
| 各连接凭据使用独立钥匙串引用，手机模型运行时直连配置的 endpoint；已有旧配置迁移后保留原地址与模型 | `Packages/MoMoAgentKit/Sources/MoMoAgent/Providers/ProviderConnectionStore.swift`；`Packages/MoMoAgentKit/Sources/MoMoAgent/Providers/ProviderAccess.swift`；`Vendor/PiDurableKit/Sources/PiDurableKit/Auth/Credentials.swift`（AfterFirstUnlockThisDeviceOnly） |
| 读取模型目录会鉴权请求服务；模型验证发送小型合成提示、随机校验值与工具定义，不读取录音／转录／聊天，不执行返回的工具调用 | `Packages/MoMoAgentKit/Sources/MoMoAgent/Providers/ProviderVerification.swift` |
| 仅允许 HTTPS 模型地址 | `Packages/MoMoAgentKit/Sources/MoMoAgent/API/AgentModels.swift` |
| 初始两小时自动正文、最多八条概况，选中录音另行取段 | `Packages/MoMoAgentKit/Sources/MoMoAgent/Context/ContextBuilder.swift` |
| 额外搜索／读取转录工具；播放在本机，不回传音频 | `Packages/MoMoAgentKit/Sources/MoMoAgent/Tools/ArchiveTools.swift` |
| 个性、关于你、记忆；修改不清除已有聊天／恢复请求 | `Apps/iPhoneApp/Features/Settings/AssistantContextSettingsView.swift`；`Packages/MoMoAgentKit/Sources/MoMoAgent/Tools/MemoryTools.swift` |
| 本机模型随包加载，缺文件时报失败 | `Apps/iPhoneApp/Bootstrap/PhoneComposition.swift`；`project.yml` |
| Watch 用户启动／暂停／标记／结束；麦克风及后台音频 | `Apps/WatchApp/Features/Capture/CaptureView.swift`；`Apps/WatchApp/Resources/Info.plist` |
| WatchConnectivity 双端传输和删除控制 | `Apps/iPhoneApp/Application/Receiving/PhoneReceiveCoordinator.swift`；`Apps/WatchApp/Application/WatchRuntime.swift`；`Apps/iPhoneApp/Bootstrap/PhoneRuntime.swift` |
| 原音默认七天、1–365 天设置，符合条件才到期清理，文字保留 | `Apps/iPhoneApp/Features/Settings/SettingsView.swift`；`Packages/MoMoAgentKit/Sources/MoMoArchive/Retention.swift` |
| 手动保留、删除、文件／分享导出 | `Apps/iPhoneApp/Features/RecordingDetail/RecordingRetentionView.swift`、`RecordingDetailView.swift`、`RecordingExportView.swift` |
| 文件共享和文档原位访问已启用 | `Apps/iPhoneApp/Resources/Info.plist` |
| 资料库文件保护／备份排除，不推广成所有数据的保证 | `Packages/MoMoAgentKit/Sources/MoMoArchive/FilePolicy.swift` |

生产目录中未发现账号、StoreKit、广告、远程统计或崩溃上报集成；此项是当前代码审查结果，新增依赖后必须复核。测试专用网络配置不作为生产默认服务写入政策。

## App Privacy 填写前的判断

本机音频及本机转写不因本机处理就构成 Apple 所定义的设备外收集。但助理会发出转录／消息及个人资料；需要核对实际提供方是否保存数据超过实时处理所需时间、用途及与账号／Key 的关联，再判断 `Other User Content` 等适用类型、是否 linked to user 及用途。不能提前保证“Data Not Collected”、完全匿名或服务商不用于训练。无广告追踪集成也不等于可以省略其他数据披露。

`PrivacyInfo.xcprivacy` 当前声明的是所用 required-reason API；它不是公开隐私政策，也不能替代 App Store Connect 的 App Privacy 问卷。

## 验证

本次为文档改动：核对生产代码路径、双语内容覆盖、链接、TODO 和 `git diff --check`。不运行构建／设备 E2E，不声称同意流程、删除／密钥清除、远端留存或最终包行为已经通过验证。下一次对外发布前，必须对照实际提交的 Release 包复核。
