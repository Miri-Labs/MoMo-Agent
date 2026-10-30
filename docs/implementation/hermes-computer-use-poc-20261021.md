# Hermes 本机 Computer Use POC

日期：2026-10-21。仅 `codex/hermes-app-20261021`，不涉及 main、真实手机或 Watch。

## 状态

**准备完成一部分，尚未打通。** 用户暂时无法操作 macOS 权限界面，已要求后续再继续；因此停止实际窗口操作验证。

- 确认内置 Hermes 的 `computer_use` 已通过 stdio MCP 调用 cua-driver，无需再造 MCP 转发服务。
- 用 Hermes 自带包管理器安装锁定的 cua-driver 0.21.0；安装器报告 runtime contract ready，并通过其 macOS bundle 签名校验与注册。
- 包管理器使用独立目录 `tmp_agent_output/computer-use/runtime/tools`；没有改用 OpenClaw 内置驱动。遥测通过环境关闭。
- 只读权限查询返回 `unknown`：没有以 CuaDriver 自身身份运行的 daemon，不能把终端已有权限当作驱动权限。随后触发系统授权流程；用户表示无法操作，已取消等待并停止本次 CuaDriver daemon。
- 本次结束时，仅原有两条 `/Applications/OpenClaw.app/Contents/Resources/cua-driver` 进程仍在；未停止或修改它们。
- `Tests/AgentRuntime/ComputerUseProbe.swift` 是仅含测试输入框、按钮与结果的原生窗口源码。按钮点击后才会写测试回执；目前仅做编译检查，未启动、未操作。

安装成功、MCP 源码存在、测试窗口能编译，都不能证明端到端执行成功。本轮没有运行真实模型，也没有用合成模型伪装完成结果。

## 分层与复用

手机/桌面客户端 → MoMo Access Service → Hermes 任务 → `computer_use` → 本机 MCP stdio → cua-driver → macOS 应用。

隧道只连接 MoMo 的认证入口。MCP 和 cua-driver 留在 Mac 本机；不把驱动端口直接暴露到公网。沿用 Hermes 的窗口发现、截图/AX 树、操作结果、会话清理以及传输结果不明时不重放输入的行为。

正式产品仍须接入驱动准备状态、系统权限状态和任务审批界面。目前 App 默认 toolset 未启用 `computer_use`，本次没有改动生产配置，也没有交付新的 App 安装包。

## 下一次继续

先由用户为这份签名 `CuaDriver.app` 授予辅助功能和屏幕录制/捕获权限。驱动完整路径：

```
tmp_agent_output/computer-use/runtime/tools/cua-driver-0.21.0-darwin-arm64/CuaDriver.app
```

在本分支根目录运行其 `Contents/MacOS/cua-driver permissions grant` 进入授权流程，随后用 `permissions status --json` 核对。不要继承其他应用的权限结论，也不要修改 TCC 数据库。

后续主线限于一次完整验证：

1. 将测试 Swift 源码编译为独立测试 App bundle，固定测试 bundle ID，传入仅供本轮使用的回执路径。
2. 用 Hermes 的 `bounded` 配置和独立会话，只允许这个测试 App 的窗口；禁用整屏访问。清单由测试启动器确定，不由模型生成。
3. 模型先回复用户，再调用 `computer_use` 获取测试窗口的实际元素；输入唯一标记，点击确认，再读取状态。
4. 同时核对原生按钮回执、实际工具结果和回复/操作时间，不能只看工具返回 `ok`。合成模型只证明管线，真实模型另标结果。
5. 仅补两条边界：清单外应用被拒绝；输入结果不明时不自动重放。结束后清理本次窗口、MCP 和私有 daemon。

参考：[驱动 0.21.0 发布](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.21.0)、[官方权限与清单说明](https://cua.ai/docs/cua-driver/guides/permissions)。Hermes 实际实现以仓库 `Vendor/HermesAgent/tools/computer_use/` 为准。
