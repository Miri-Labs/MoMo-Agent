# Gemini 实现补丁复审原文

模型：`gemini-4-carbon-high`，effort `high`。会话：`e646f8b6-82b5-4392-a105-e12bb9058c28`。

以下为模型原文，精确路径/行号可能含误写或工作树时序混淆，以主审处理记录与最终源码为准。初审关于旧 Mac 已返回 workspace_id 的描述已在复审更正；复审中的 `Tests/HermesRuntimeTests` 应为 `Tests/AgentRuntime`。

---

### 复审结论：**通过代码合入检查（无新增阻塞项）**

针对 `fixes.diff` 及关联源码段的聚焦复审已完成：上轮指出的 3 项缺陷与挂起配对切后台边界均已闭环修复，未引入新的并发竞争、代次污染或身份校验退化。当前实现**已满足代码合入门槛**；真实网络切换与长后台恢复表现归属**真机验收门槛**。

---

### 一、逐项修复核查

1. **配对互斥与场景取消隔离（原 P1-1 + 挂起配对切后台）：已修复**
   - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L38-L40) 将状态拆分为 `pairingInProgress` 与 `recovering`（计算属性 `connecting` 聚合两者供通用状态展示）。
   - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L135-L186) 中 `connect(...) -> Bool` 仅以 `guard !pairingInProgress else { return false }` 拒绝第二个并发显式配对（不覆盖在途 `failure`），随即调用 `cancelRecovery()` 抢占自动恢复；凭据落盘与切换 store 成功后、触发 `if active { beginRecovery() }` 前先置回 `pairingInProgress = false`（L177-L178），避免阻塞配对后的首轮恢复，且仅在完整成功时返回 `true`。
   - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L212-L221) 的 `cancelRecovery()` 仅复位 `recovering = false`，`leavingForeground()` 不会误释放挂起中的 `pairingInProgress` 互斥锁。
   - [PhonePairing.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhonePairing.swift#L81-L85) 与 [PhoneRemoteView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteView.swift#L484-L491) 均改为仅在 `connect(...) == true` 时清理暂存密钥或关闭手动配置页，提交按钮仅绑定 `pairingInProgress`，消除了自动恢复抢占导致的密钥误删与假成功。[BackgroundGrantLifecycleTests.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/iPhoneIntegrationTests/BackgroundGrantLifecycleTests.swift#L256-L314) 新增的两项抢占与切后台保锁用例逻辑已核对无误（本轮模拟器由你侧另跑）。

2. **笔记通道 `workspace_id` 校验、旧版兼容与缓存隔离（原 P1-2）：已修复**
   - 更正说明：原基线 `dc26d9e8` 的 Mac 端确无 `workspace_id`（上轮读到了工作树未提交补丁），本次由 [context_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/context_server.py#L138) 正式向 `/v1/memories` 响应注入 `workspace_id`，并在 [ContextClient.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/ContextClient.swift#L112) 新增 `MemoryPage.workspaceId`。
   - [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L612-L636) 在 `downloadMemories` 分页拉取时逐页强校验 `workspace == state.connection.workspaceID`；对接无此字段的旧版 Mac 时，提交前在同一 `memoryGeneration` 代次内先调用 `contextStatus()` 完成 `validate(status)`，若取消、失代或 status 不可达则中止提交并保留原缓存；已由内容响应验证身份的新版笔记不受旁路 `startMemoryReview()` 成败影响。
   - [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L86-L116) 为 `MemoryCache` 持久化 `workspaceID`：读取时跨 workspace 直接抛 `SyncError.identity` 拒绝；缺省 `workspaceID` 的旧独立缓存不展示内容并等待刷新；无独立缓存文件时仍兼容经 `hasSameIdentity` 校验的旧 `context.json`。

3. **`reconnect()` 合并轮次等待与手动意图保留（原 P2-1）：已修复**
   - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L204-L210) 记录快照 `scene = sceneGeneration` 并循环等待当前 `recoveryTask`；结合 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L245-L251)，`@MainActor` 串行调度保证首轮 `defer` 在唤醒 `await current.value` 前同步赋好补发的 `recoveryTask`，`self.active || manual` 确保非活跃态下也不丢弃显式手动重连，场景切换触发 `cancelRecovery()` 时则随 `sceneGeneration` 递增即时退出等待。

---

### 二、本次实跑测试结果

本轮亲自执行 `/private/tmp/momo-implementation-review-20261114/run-check all`（退出码 `0`；`skip` 不计为通过；本轮未亲跑模拟器与真机）：

- **MoMoAgentClientTests**（`client.log`）：执行 158 项 —— **157 pass / 0 fail / 1 skip**（`RelayTests.testNativeClientAgainstUpstreamRelayAndPythonResponder` 因未启动外部 Python relay fixture 跳过）。
- **RemoteContextSyncTests**（`sync.log`）：执行 22 项 —— **22 pass / 0 fail / 0 skip**（含新增 4 项跨 workspace 拒写、无身份旧独立缓存等待刷新及旧版 Mac 降级校验测试）。
- **Tailnet 探针**（`tailnet.log`）：**7 组 PASS / 0 fail / 0 skip**。
- **Python 记忆测试**（`memory.log`）：执行 11 项 —— **11 pass / 0 fail / 0 skip**（含 [test_momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/HermesRuntimeTests/test_momo_memory.py#L138-L139) 新增的 HTTP `/v1/memories` `workspace_id` 断言）。

---

### 三、代码门槛与真机门槛区分

- **代码合入门槛（已满足，无新增阻塞）**：并发代次隔离、配对与恢复双状态机、笔记 `workspace_id` 端到端校验及错误退避逻辑均已验证完备，配合你侧另跑通过的模拟器测试即可提交合入。
- **真机验收门槛（合入后实机必验）**：
  1. 双端升级同版本并回读确认线上 `/v1/memories` 返回匹配 `workspace_id`；
  2. 针对原用户“42 分钟笔记不刷新/断联”场景，实测手机锁屏/切后台 ≥45 分钟、Wi-Fi↔蜂窝/Tailscale 切网及 Mac 睡眠唤醒，确认回前台数秒内笔记刷新与聊天连接自动恢复；
  3. 按需拉起 `serve_relay_interop_fixture.py` 补验 1 项跳过用例。
