# MoMo 内置能力自知修复（2026-11-15）

## 根因与证据

这次证据支持提示词与能力发现路径缺口，不能据此判定安装或配置损坏。

- `Apps/MacApp/Runtime/superagent_runtime.py` 的 `skills.momo` 原本已说明 `agent-desktop` 和两个桌面工具；`runtime/shared` 却只给主会话泛化的“Mac 桌面控制”，并无条件声称 Worker 拥有完整执行能力。
- `Vendor/SuperAgent/src/app/sessions.ts` 的 `decorate` 将主会话提示词设为 `complete: true`，用 `Prompts.compose` 装配；`bindSkills` 单独注册 skills，并不把 skill 正文拼进主提示词。`prompts.ts` 的 `promptParts` 证实这一点。原主提示词没有明确引导读取现有能力说明。
- `src/app/runtime.ts` 分别调用 `mainTools` / `executorTools`。`tools/momo-computer.ts` 仅在 MoMo data 与 loopback bridge 存在时返回桌面工具，入口属于 Worker。主会话看不到它们是角色边界，不是未安装证据。
- `Vendor/AgentDesktop/UPSTREAM.json` 固定后端为 `vercel-labs/agent-desktop` v1.0.2；Mac 的 `AgentDesktopDriver.swift` 加载包内动态库，`DesktopControlHost.swift` 另行检查辅助功能权限。打包、注册、授权、成功执行不能互相代替。

## 改动

只修改 MoMo 的 Python 提示词配置。主提示词与按需 skill 共用一段电脑能力说明，首轮即包含后端、Worker 入口、浏览器与原生桌面的区别，以及状态证据边界。

能力发现复用已有 `orchestrator_read(resource='prompts')`：从当前配置获取内置/团队 skill 名称，按返回 revision 分页读取说明，不新增另一份完整工具/插件清单。它不是所有文件系统 skill 或插件的全局清单；浏览器能力仍须依据当前实际 skill 发现。说明不代表工具已注册或服务已连接，不能因为 lark CLI 存在就宣称飞书已连接。

没有增加执行工具、改变角色过滤、路由实现或权限门禁，也没有修改 Vendor、依赖版本或应用版本。沿用现有三方提示词升级逻辑：更新未定制的默认段落，保留用户定制段落与主动删除的 skill。因此已定制的 `runtime/shared` 不会被强制覆盖。

## 本地验证

- 用修改前基线 `2810c067` 的配置走真实 `composePrompt`：首轮测试明确失败，主提示词缺少 `agent-desktop`。同一测试使用修改后配置通过。
- `Tests/AgentRuntime/capability-awareness.spec.ts`：**5/5 通过**。实际调用 SuperAgent 的提示词装配、主/Worker 工具工厂和只读发现资源；核对 backend manifest 与工具名称漂移、缺少桥接环境时不注册、skill 增删、未配置飞书时不列出其 skill，以及完整分页读取。
- Python：**16/16 通过**，包括新增 `test_capability_awareness`、已有 `test_superagent_runtime.RuntimeEngineConfigTests` 和 `test_agent_desktop`。覆盖默认提示词升级及定制保留、权限/组件缺失错误原样返回、不重试，以及控制权、停止和观察边界。
- 初始默认 Python 环境缺少 aiohttp / mcp；随后使用临时 uv 缓存，按仓库 lock 中的 aiohttp 3.14.3、mcp 2.3.0、PyYAML 6.0.3、cryptography 50.0.1 运行并通过。JS 复用已有 Vitest 4.1.8 依赖，不更改依赖文件。

核心命令（JS 依赖须可从工作区及 Vendor/SuperAgent 解析）：

```sh
node Vendor/SuperAgent/node_modules/vitest/vitest.mjs run Tests/AgentRuntime/capability-awareness.spec.ts --cache=false
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Tests/AgentRuntime uv run --no-project --with aiohttp==3.14.3 --with mcp==2.3.0 --with pyyaml==6.0.3 --with cryptography==50.0.1 python -B -m unittest test_capability_awareness test_superagent_runtime.RuntimeEngineConfigTests test_agent_desktop -q
```

这些是提示词与运行时契约回归，未调用真实模型，不能证明每次生成的回答都会正确。**尚未部署**：未构建 App、安装、重启、变更 live profile、读取用户聊天数据或更改隐私授权；也未包含 Enter-to-send 改动。

收尾删除本轮临时 uv 缓存、基线验证副本及两处依赖符号链接；未生成 App 构建产物，未清理其他任务的共享依赖。磁盘实际可用空间约 18 GiB。
