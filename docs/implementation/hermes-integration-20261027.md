# Hermes 三项修复整合 · 2026-10-27

全部代码已整合到 `/Users/syh/Workspace/MoMoAgent-worktrees/hermes-app-20261021`，分支 `codex/hermes-app-20261021`，HEAD 仍为 `eab661fa007406e5d38b33d6d4308a1542232e5a`。这是**未提交的工作区整合**：逐文件三路合并，保留原有配对、重连、UI 和设计稿改动。没有改 main、创建提交、推送、安装或重启用户服务。

| 项目 | 代码与本地验证 | 实机/部署状态 |
| --- | --- | --- |
| 控制电脑 / OpenUU 思路 | 连续采集、JPEG 流、两帧确认窗口、独立媒体/控制连接、首帧就绪与接管生命周期已整合 | 真实跨网画面和键鼠接管未验收；不是完整 H.264/RTP 视频移植 |
| MoMo-REPLY-DELIVERY-20261027 | 修复 inactive 提前断开、订阅退出后不恢复；增加有限后台接收；恢复前台/重开按持久游标补齐 | 后台、锁屏、断网、冷重开真实手机未验收 |
| MoMo-REPLY-PUSH-20261027 | 核对 APNs alert 链路，补精确消息定位、定位校验与设备注册重试等待 | 用户确认无通知服务，本轮交付代码＋配置清单；未发送真实 APNs |

## 合并后的验证

命令均在 Hermes 目标工作树执行。完整日志在 `/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/hermes-integration-20261027/`。

```sh
swift test --package-path Packages/MoMoAgentAgentClient --scratch-path /tmp/momo-hermes-integration-client
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' -m unittest Tests.AgentRuntime.test_desktop_control Tests.AgentRuntime.test_conversation_events Tests.AgentRuntime.test_personal_agent Tests.AgentRuntime.test_push_notifications Tests.AgentRuntime.test_pairing
swift Tests/Support/chat-notification-focus-smoke.swift
swift Tests/Support/chat-history-stability-smoke.swift
```

- Swift package：**105 项、0 失败**。
- Python：**55 项、OK**，包含画面、回复持久化、推送和既有配对恢复回归。
- 实际 WKWebView：通知定位、后补消息、重复意图、保持 DOM/阅读位置通过；历史稳定性测试通过。
- UIKit 生命周期模拟器 probe：短暂失活、有限后台接收、到期、授权拒绝及旧回调隔离通过。不是系统真实调度/锁屏验收。
- XcodeGen **2.46.0** 重新生成工程。`MoMoAgentMac` / `MoMoAgentBeta`、`Beta` configuration 分别使用 `generic/platform=macOS` / `generic/platform=iOS`，关闭签名并完整构建：均 **BUILD SUCCEEDED**。源码依赖使用已有缓存，没有安装依赖。
- 编译产物身份：`MoMoAgent Beta` / `com.momoagent.ios.beta` / 1.34.17 / development。本轮没有交付安装新版本，未递增已安装版本号。未签名构建不能证明 push entitlement 或设备授权有效。

当前 Mac 仍运行原 Beta 1.34.17；本轮 iPhone 只读开发连接返回 CoreDeviceError 4016，没有改动已装 App。

## 分项记录

- [控制电脑证据与实现](openuu-desktop-preview-20261027.md)
- [问题1：回复送达](reply-delivery-20261027.md)
- [问题2：系统推送](reply-push-20261027.md)
- [APNs 配置清单](apns-setup-checklist-20261027.md)

三个隔离工作树保留以便复查，目标 Hermes 中已有全部修复；不再需要手工挑取这些分支的补丁。构建缓存清理后保留源码、补丁和验证日志。
