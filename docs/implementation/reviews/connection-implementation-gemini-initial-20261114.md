# Gemini 实现初审原文

模型：`gemini-4-carbon-high`，effort `high`。会话：`e646f8b6-82b5-4392-a105-e12bb9058c28`。

以下为模型原文，精确路径/行号可能含误写或工作树时序混淆，以主审处理记录与最终源码为准。初审关于旧 Mac 已返回 workspace_id 的描述已在复审更正；复审中的 `Tests/HermesRuntimeTests` 应为 `Tests/AgentRuntime`。

---

### 1. 代码合入检查结论（针对基线 `dc26d9e8`，diff `4af63c1a..dc26d9e8`）

**结论：不通过直接合入（阻塞项：2 个 P1，次要项：1 个 P2）。**

整体架构改造扎实：`AgentTransportFailure` 白名单分层、`EmbeddedTailnet` 节点与连接池双代次 + 60 秒重建预算、Mac `DesktopModel` 配置拒绝过期转 `needs_setup`、`PhoneContextDelivery.expire()` 先取消内层同步再释放传输与 OS grant、`PhoneContextSync` 笔记/上传通道解耦、500 条积压首错即停、413 单条隔离以及 `Source.spans` / `applySpeakerCorrections` 边界均与冻结方案一致。但在 `dc26d9e8` 实现中存在 **2 个本次改动新引入的确定性 P1 缺陷**（涉及重配对密钥丢失/假成功、独立笔记通道缺少 `workspace_id` 身份校验）和 **1 个 P2 协调缺陷**，需修复并补齐单测后再合入。

---

### 2. 已确认可执行缺陷（最多 3 项，均基于 `dc26d9e8` 源码核实）

#### [P1-1] 自动恢复复用 `connecting = true` 并清空 `failure`，导致扫码重配对时 `connect` 静默空退、误删新批准密钥并展示假「配对成功」（本次新增缺陷）

- **文件 / 函数 / `dc26d9e8` 行号**：
  - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L133-L136) `connect(configuration:credential:)`（第 134 行 `guard !connecting else { return }`，第 167 行才调 `cancelRecovery()`）
  - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L227-L256) `beginRecovery(userInitiated:trigger:)`（第 228 行 `connecting = true; failure = nil`，直至 12 秒 `probeCapabilities` 及 `await chat; await memories` 结束才在 `defer` 复位）
  - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L307) `foreground()`、[PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L372) `startPathMonitor()`
  - [PhonePairing.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhonePairing.swift#L71-L76) `resume(agent:name:)`
- **与基线差异**：`4af63c1a` 中 `foreground()` 与 `pathUpdateHandler` 从不修改 `connecting`；本次统一恢复入口后，自动前台恢复与网络切换都会在 `store.canContactServer == true`（涵盖 `.ready` / `.retrying` / `.unavailable`）时置 `connecting = true` 并清空 `failure = nil`。
- **可发生的事件时序与影响**：
  1. 用户已有旧配对（`agent.store != nil` 且 `canContactServer == true`，例如换了路由/地址导致旧入口不可达处于 `.retrying` 或 `.unavailable`），打开「重新配对」进入 `PhoneConnectionFlow(reconnecting: true)`；
  2. 扫码切回前台（第 307 行）或登录 Tailscale / 切 Wi-Fi 触发 `NWPathMonitor`（第 372 行），调用 `beginRecovery()`，置 `agent.connecting = true`、`agent.failure = nil`（第 228 行），对不可达的旧 `desktopClient` 执行最长 12 秒 `probeCapabilities`（第 244 行）；
  3. 12 秒窗口内 Mac 批准新配对，`PhonePairing.resume` 第 74 行执行 `await agent.connect(configuration: configuration, credential: value.credential)`；
  4. `connect` 在第 134 行命中 `guard !connecting else { return }` **直接静默返回**（未走到第 167 行 `cancelRecovery()`），新密钥未写入 Keychain，新 `connection.json` 未保存，且 `agent.failure` 仍为 `nil`；
  5. `PhonePairing.resume` 第 75 行见 `agent.failure == nil`，在第 76 行执行 `try clear(); completionGeneration += 1`，**永久删除 `pending-pairing.json` 中刚获批的设备密钥 `value.credential`**，同时 [PhoneConnectionFlow.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneConnectionFlow.swift#L13) 判定 `ready == true` 显示「配对成功 / 配对已验证」，但手机实际仍停留在旧连接与旧密钥上。
- **最小复现与修复建议**：
  - **复现**：构造已有 `store` 且旧 `desktopClient` 的 `/v1/capabilities` 挂起 10 秒，调用 `agent.foreground()` 后立即运行 `pairing.resume` 返回 `"approved"` 新地址/新密钥，可见 `pending-pairing.json` 被清空而 `agent.connection` 未更新。
  - **修复**：将显式配对连接互斥状态（如 `isApplyingConnection`）与 `recoveryTask` 状态拆开；`connect(...)` 开始或切换提交前取消在途 `recoveryTask`，且 `connect(...)` 绝不能在未生效时保持 `failure == nil` 静默返回（建议改为 `throws` 或返回明确 `Bool` 供 `PhonePairing.resume` 与手动保存页判断）。

---

#### [P1-2] 笔记通道独立后，`/v1/memories` 未校验响应 `workspace_id` 且 `MemoryCache` 未绑定 `workspaceID`，存在跨 workspace 缓存污染退化（本次新增缺陷）

- **文件 / 函数 / `dc26d9e8` 行号**：
  - [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L83-L89) `MemoryCache` 定义及 [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L102-L108) `init` 读取校验
  - [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L183-L231) `synchronizeMemories()` / `refreshMemoryReview(owner:)`
  - [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L601-L621) `downloadMemories(owner:)`
  - 服务端对照：[context_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/context_server.py#L135-L139) `/v1/memories` 已返回 `result["workspace_id"] = connection["workspace_id"]`
- **与基线差异**：`4af63c1a` 中 `downloadMemories()` 位于 `synchronizeArchive` 内，必须先通过 `/v1/status` 的 `guard status.workspaceId == state.connection.workspaceID` 才会拉取笔记。拆出独立笔记通道后，`startMemoryReview()` 变为非阻塞旁路任务（第 183、208 行），其 `validate(status)` 失败（第 220、226 行）既不中止 `downloadMemories`，也不记录身份错误。
- **可发生的事件时序与影响**：
  1. 远端同 `instanceID` 进程切换到不同 `workspace_id`（或代理/端口误指同实例密钥下的另一工作区）；
  2. `synchronizeMemories()` 并发触发旁路 `refreshMemoryReview` 与 `downloadMemories(owner:)`；
  3. `refreshMemoryReview` 发现 `status.workspaceId != state.connection.workspaceID` 抛出 `SyncError.identity`（第 239–240 行），在第 226–230 行被静默忽略；
  4. `downloadMemories(owner:)` 拉取 `/v1/memories`（第 607 行）时未核对响应 `workspace_id`，直接将不匹配工作区的笔记写入 `memories-cache.json`（第 616–620 行）并更新 UI；下次冷启动 `init` 第 105 行也仅校验 `(libraryID, instanceID)`，漏掉了第 97 行 `hasSameIdentity` 原有的 `workspaceID` 约束。
- **最小复现与修复建议**：
  - **复现**：Fixture 中令 `/v1/status` 与 `/v1/memories` 返回不同于 `connection.workspaceID` 的 `workspace_id`，执行 `await sync.refreshMemories()`，断言可见跨工作区笔记被落盘并展示。
  - **修复**：在 `MemoriesPage` 解码可选 `workspaceID` 并在 `downloadMemories` 中强制校验（存在时必须等于 `state.connection.workspaceID`，旧服务端若缺省则需依赖同代次已通过的 `status` 身份确认）；`MemoryCache` 增加 `workspaceID: UUID`（或完整 `AgentConnection` 身份校验）；`refreshMemoryReview` 遇到 `SyncError.identity` 时取消当前 `memoryTask` 并暴露身份错误。

---

#### [P2-1] 手动 `reconnect()` 撞上在途自动恢复时提前返回，未等待合并补发的手动恢复完成（本次新增缺陷）

- **文件 / 函数 / `dc26d9e8` 行号**：
  - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L197-L200) `reconnect()`
  - [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L215-L218) `beginRecovery` 排队逻辑与 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L235-L241) `defer`
- **可发生的事件时序与影响**：
  1. `foreground()` 或 `network-path` 正在执行自动恢复 `Task_1`（`userInitiated == false`，不会调用 `allowSourceDeliveryRetry()` 清 413 失败标记，也不会在 401 状态下执行恢复）；
  2. 用户点击「重试 / 重新连接」调用 `await agent.reconnect()`；
  3. `beginRecovery(userInitiated: true)` 在第 216 行置 `queuedRecovery = true` 后返回，`recoveryTask` 仍是 `Task_1`；
  4. 第 199 行 `await recoveryTask?.value` 只等待 `Task_1` 完成即返回给调用方，此时 `defer` 第 239 行刚派发的 `Task_2`（真正携带 `userInitiated: true` 的恢复任务）尚未完成；若在非 `active` 状态下直接调用 `await agent.reconnect()`，第 239 行 `if self.active` 为假还会直接丢弃该排队重试。
- **最小复现与修复建议**：`reconnect()` 改为循环 `while let current = recoveryTask { await current.value }`，保证调用方等到合并补发轮次真正结束。

---

#### 其余重点审查项核对结果与未确认边界

- **已核实无新缺陷的重点项**：
  - **取消后旧任务回调与清理隔离**：`PhoneContextSync` 的 `sourceGeneration` / `memoryGeneration` / `reviewGeneration`（第 164–170、192–195、288–291、608–616 行）与 `EmbeddedTailnet` 的 `sessionGeneration`（第 309、369–370、594、611–621 行）均在取消时立即轮换代次；新请求检查 `!isCancelled` 不复用已取消 `Task`，旧 `defer` 不会清空新句柄，删除笔记后旧分页响应无法复活已删笔记。
  - **并发 stage / ACK / 删除合并**：`PhoneContextSync.stage` / `deliver` / `uploadSources`（第 414–460、539–543、569–572 行）每次 `await` 后均基于最新内存 `state` 比对 `envelope` 或 `(generation, version)` 后单条合并，上传回执不会覆盖并发新版本或重写笔记缓存。
  - **旧 401 与连接恢复门控**：`/v1/capabilities` 在 [access_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/access_server.py#L104) 经过 `self.store.authorized(...)` 真实鉴权；`PhoneRemoteAgent.connectionConfirmed`（第 271–282 行）校验 `store === confirmedStore && active && confirmedStore.canContactServer`，同 `sceneGeneration` 下新认证流量推进 `connectionConfirmation` 后，迟到的旧探测瞬时失败不会覆盖新成功（第 262 行）。
- **明确标记未在本次只读窗口内逐行读完的部分（不作无证据断言）**：
  - 未逐行通读 `RelayTransport.swift`、`AgentRTCTransport` 实现文件及 `momo_agent.py` 主进程源码（仅通过 `access_server.py`、`context_server.py`、`tunnel.py` 与下列实跑测试日志核对了跨端契约）。

---

### 3. 本次亲自运行的命令与真实结果

本次在隔离目录亲自执行了受限验证脚本：

- **执行命令**：`/private/tmp/momo-implementation-review-20261114/run-check all`（总退出码：`EXIT 0`）
- **分项真实结果（严格区分 pass / fail / skip）**：
  1. **`client`**（`swift test --package-path /private/tmp/momo-implementation-review-20261114/client-check --jobs 2`，日志 `client.log`）：
     - `EXIT 0`；共执行 **158 项**：**157 passed，0 failed，1 skipped**。
     - **Skip 明细（不计入通过）**：`RelayTests.testNativeClientAgainstUpstreamRelayAndPythonResponder`（`RelayTests.swift:76`，因缺少本地启动的 `serve_relay_interop_fixture.py` 跳过）。
  2. **`sync`**（`uv run --no-project python Tests/Support/run-recording-summary-tests.py --scratch-path /private/tmp/momo-implementation-review-20261114/sync-build`，日志 `sync.log`）：
     - `EXIT 0`；`RemoteContextSyncTests` 共执行 **18 项**：**18 passed，0 failed，0 skipped**。
  3. **`tailnet`**（`uv run --no-project python Tests/Support/test-tailnet-recovery.py`，日志 `tailnet.log`）：
     - `EXIT 0`；**7 组探针全部 PASS，0 failed，0 skipped**（含节点重建 60s 限频与 ATS 策略拒绝不重建节点）。
  4. **`memory`**（`uv run --no-project --with aiohttp python -m unittest discover -s Tests/AgentRuntime -p test_momo_memory.py`，日志 `memory.log`）：
     - `EXIT 0`；**11 passed，0 failed，0 skipped**。

> **证据边界声明**：实施文档中记录的 iPhone 17 Pro 模拟器 25 项（`PhoneContextDeliveryTests` 7 项 + `RemoteContextSyncTests` 18 项）仅只读核对了 `connection-upgrade-final-tests.json` 摘要，**非本人本次亲跑**；本次**未**验证真机、真实 Tailscale 跨网线路或已安装 Mac 服务重启。

---

### 4. 当前仍缺的测试与原用户「42 分钟笔记不刷新 / 断联」验收方法

#### 还缺的自动化测试
1. **`PhoneRemoteAgent` 生命周期与配对协调单测（当前空白）**：覆盖「自动恢复 `probeCapabilities` 挂起期间执行扫码 `connect(...)` 不丢密钥、不静默返回」「`reconnect()` 撞上在途自动恢复时完整等待补发轮次」「`network-path` 连续抖动合并单飞」「旧 `sceneGeneration` 迟到失败不覆盖新恢复」。
2. **笔记跨 `workspace_id` 拒绝落盘单测**：在 `RemoteContextSyncTests` 注入 `workspace_id` 不匹配的 `/v1/memories` 与 `/v1/status` 响应，验证拒绝写入 `memories-cache.json` 并保留原缓存。
3. **Relay 真实互操作测试去 skip**：启动 `serve_relay_interop_fixture.py` 实跑 `RelayTests.testNativeClientAgainstUpstreamRelayAndPythonResponder`，消除当前唯一 skip。

#### 原用户「42 分钟笔记不刷新 / 断联」真机验收步骤
1. **先对齐双端版本与提交**：将修复提交打包签名后安装到测试 Mac 与 iPhone Beta（遵循 `verify-mac-beta.py` 与 `com.momoagent.ios.beta` 隔离规则），实机回读两端版本号与构建号一致（消除此前 Mac 仍跑 `0.6.20 / 111` 的版本漂移）。
2. **构造真实积压与后台挂起复现链**：
   - 在手机端保留待上传录音转录积压（或持续佩戴手表/耳机录音产生新分片），确认初始 `lastSynced` 时间；
   - 将手机退入后台锁屏静置 **45 分钟**（覆盖原 42 分钟窗口）及 **2 小时**，期间在 Mac 端新增/更新一条 Markdown 记忆笔记，并经历一次 Wi-Fi ↔ 蜂窝切换或 Mac 睡眠唤醒；
3. **回到前台的判定标准（缺一不可）**：
   - **无需重新扫码或手动杀进程**：解锁回前台后，记录 `T0`（网络与 Mac 可达时刻）、`T_connected`（`recovery` 诊断记录 `authenticated`）、`T_synced`（`memories-cache.json` 原子更新完成）；
   - **恢复时延与独立性**：即使后台仍有录音原文正在上传（`isUploadingSources == true`）或 `/v1/status` 慢响应，笔记页必须在 `T_connected` 后数秒内（目标 P95 ≤ 10s）展示 Mac 新增笔记，「上次同步」相对时间真正刷新为刚刚；
   - **诊断日志核查**：检查双端诊断日志，确认无 60 秒内重复节点重建风暴、无 ATS `-1022` 伪装 `reconnecting` 循环、无后台到期导致的伪 `sourceDeliveryFailure` 残留。
