# Gemini 第二轮复审原文

模型：`gemini-4-carbon-high`；effort `high`；agy 会话 `2a4b7d87-8fc2-4912-90b0-dfeda6f64453`。

主审处理：接受经源码核实的三项实施边界与首轮 P0–P2 范围；P3/P5 仍为后续阶段。当前代码实施和验证另行记录。

---

# MoMo Agent 连接升级方案：第二轮独立复审结论

- **复审依据**：[connection-upgrade-round1-response.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/implementation/reviews/connection-upgrade-round1-response.md)、[mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md) 及基线 `4af63c1aaa7c047136a0527f531feae67379a209` 对应源码。
- **最终结论**：**有条件准予进入首轮（`P0–P2`）实施**。复核响应中的「采纳项 1–8」与 `R1–R8` 证据扎实；在将采纳项与下述 **3 个首轮实现安全边界**同步补充进方案文本后，即可进入 `P0–P2` 代码实施（`P3`、`P5` 维持独立后续阶段，不混入首轮）。

---

## 一、对 `R1–R8` 及采纳项的逐项复核（撤回 / 修正 / 保留）

1. **R1（CIDR ATS 例外与 `-1022`）——【撤回旧版 ATS 判断，保留 Mac 自检过期状态修正】**
   - **撤回**：Apple 现行 `NSExceptionDomains` 文档明确自 iOS 17 / macOS 14 起支持 IP 字面量与 CIDR，本项目最低目标为 `macOS 14 / iOS 18`（[Package.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Package.swift#L6)）。撤回第一轮“CIDR 无效、删除 `100.64.0.0/10`、改用全局 ATS 选项”的错误建议；继续保留两端 `Info.plist` 的 `100.64.0.0/10` 例外与 [TailnetEndpoint.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/TailnetEndpoint.swift#L7-L21) 的 CGNAT 约束。现场 `-1022` 标为**待按实机安装包与实际请求 URL 复现**。
   - **保留（归入 P1）**：[DesktopModel.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/DesktopModel.swift#L816-L827) 捕获 `-1022` 后，一旦 `embeddedHealth.recentlyVerified(url)` 60 秒窗口过期或睡眠唤醒重置 `embeddedHealth`（第 188 行），第 826 行仍上报 `state: "reconnecting"`。按方案第 96 行，过期后应改为明确上报自检/配置检查失败，既不重启仍在服务的节点，也不长期伪装为“正在重连”。

2. **R2（`MoMoMemory.list` 版本算法与快照一致性）——【撤回错误算法描述与 mtime 缓存建议，保留读侧无锁事实归入 P3】**
   - **撤回**：[momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L747-L786) 确系按单条正文 SHA-256 及排序后清单 SHA-256 计算 `revision`；撤回第一轮完全失实的 `(len(items), max(updated_at))` 描述，以及无法发现“同尺寸且保留 mtime 外部编辑”的 `(mtime_ns, size)` 缓存建议。
   - **保留（仅限后续 P3）**：读路径 `store()` / `items()`（第 645–654、757–785 行）未持有写路径的 `.md.lock` 或 `.notebooks.lock`，并发多步写入时存在跨文件读取中间态风险。原方案第 144 行已覆盖短临界区与前后摘要核验，留在 `P3` 实施即可，不阻塞首轮。

3. **R3（`URLError.badURL` 分类兼容）——【撤回对原方案的失实归因，修正分类条件】**
   - **撤回**：原方案第 86–100 行并未写出 `configurationRejected` 或把 `.badURL` 列为永久错误，撤回“原方案缺陷”定性。
   - **修正（赞同采纳项 1）**：核对 [ConversationSubscriptionTests.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Tests/MoMoAgentClientTests/ConversationSubscriptionTests.swift#L203-L218) 确有注入无 `NSUnderlyingErrorKey` 的裸 `URLError.badURL` 回归用例。因此不能把 underlying error 作为唯一允许条件；应在已通过端点校验的专用通道/代理上下文中保留 `.badURL` 的有界连接池修复兼容，同时将 `-1022`、TLS 证书错误（`-1200…-1206`）等明确移出 [AgentTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/AgentTransport.swift#L23-L35) 的 `isSocketOrLinkFailure`。

4. **R4（`PhoneContextDelivery.expire` 顺序与 `checkProxyIfNeeded`）——【撤回顺序读反，修正真实触发链】**
   - **撤回并修正**：[PhoneContextDelivery.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextDelivery.swift#L95-L101) 原文确为 `task?.cancel()`（97 行）→ `finish(...)`（99 行）→ `cancel()`（100 行，对应 `context?.cancelSynchronization()`），撤回“先 finish 后取消 task”的误读。真实细微竞争是第 99 行 `finish` 内的 `suspend()` 先销毁共享 Tailnet `URLSession`，第 100 行才取消 `PhoneContextSync.inFlight`，可能令 `inFlight` 先收到会话断开 `URLError` 误写一次 `sourceDeliveryFailure`；将第 100 行 `cancel()` 移至第 99 行 `finish(...)` 之前，仍保持同步归还 OS grant，即可消除该竞争。
   - **修正 `checkProxyIfNeeded`**：[EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L561-L607) 第 573 行确实创建了独立 `probe` `URLSession`，不受 `suspendSessions()` 池失效直接取消。真实风险是 `suspendSessions()` 未取消 `proxyCheck` Task，挂起期间 `probe` 超时报错会在第 598 行因节点 `generation` 未变而误置 `needsRestart = true`。按采纳项 4 增加会话/probe 级取消边界即可解决。

5. **R5（Relay 流中断、SSE 重建与 8 MiB 限制位置）——【撤回三处失实表述，保留 fixture 实测要求】**
   - **撤回**：① 8 MiB 普通响应累计上限确在 [AgentClient.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/AgentClient.swift#L116)，不在 `RelayTransport.swift:109`；② 正常 WebSocket 关闭不会返回 `.string` 关闭帧；③ [RemoteTaskStore.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RemoteTaskStore.swift#L483) 与第 1133–1136 行前台每 2 秒会检查 `subscription?.isRunning == false` 并重建，不会“只能切后台恢复”。以上三点撤回。
   - **保留**：严格禁止降级密钥/身份/GCM 验签失败；仅补充真实 Relay fixture 断流与 75 秒空闲超时（[RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L108)）测试，确认退避节奏符合预期（避免非瞬时错误退出订阅内建退避后被外层 2 秒定频循环紧密重建）。

6. **R6（已回执 `Source.spans` 裁剪）——【完全接受驳回，撤回清空 `spans` 建议】**
   - **撤回**：核对 [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L84-L91)、第 246–251、268–271 与 278–291 行完全属实：`sources` 计算属性、`prepareSubmission` 录音引用校验及 `stage()` 缓存命中均直接依赖保留的 `saved.envelope.spans`，且第 286 行 `pendingTranscriptionRanges` 变化置空 `receipt` 后会重投 `saved.envelope`。直接清空 `spans` 会破坏录音引用讨论并可能在重投时覆盖远端转写。完全接受驳回。

7. **R7 & R8（未承诺的 batch POST / 双通道回退及无依据百分比）——【全部撤回】**
   - 撤回将批量 ID POST 接口与首轮自动中继回退归为原方案缺陷的表述（原方案第 142、172、186 行已界定边界）；撤回无实测统计支撑的百分比与 `ContextService` 已开启 gzip 的无据假设。

---

## 二、真正阻塞首轮 `P0–P2` 实施的剩余具体问题（3 项）

在合入采纳项 1–6 后，开始写 `P0–P2` 代码前只剩以下 **3 个必须明确锁定的实现边界**：

1. **【阻塞点 1：拆开笔记下载与资料上传时，`/context/v1/status` 的读写副作用切分】**
   - **源码位置与触发条件**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L333-L353) 当前由 `synchronizeArchive` 调一次 `client.contextStatus()`，既更新笔记页展示用的 `memoryPending` / `memoryNeedsReview` / `memoryReview`（见 [RemoteMemoryView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift#L313)），又执行会改写本地 `ArchiveStore` 并回发 `acknowledgeSpeakerRelabels` 的 `applySpeakerCorrections(status)`（第 364–398 行）。
   - **风险与约束**：若将 `applySpeakerCorrections` 放入笔记刷新任务，会与上传任务的 `stage()` 并发读写 `ArchiveStore` 产生旧说话人回写竞争；若只留在上传任务而笔记任务完全不读状态，无上传时笔记页「正在整理…」状态不更新。
   - **解决要求**：**`applySpeakerCorrections` 必须严格留在资料上传通道串行置于 `uploadSources()` 之前**；笔记刷新通道只做只读 `memories` 分页拉取（可附带只读解析 `contextStatus` 的 `memoryReview` 字段而不执行 `applySpeakerCorrections`，且 `contextStatus` 失败不阻断 `memories` 读取或独立处理）。

2. **【阻塞点 2：`prepareSubmission` 录音引用直投与后台 `uploadSources` 的状态合并及回滚兼容】**
   - **源码位置与触发条件**：用户发送带录音引用的聊天消息时，[PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L451-L453) 调用 `prepareSubmission`（[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L235-L273)），直接绕过上传任务并发执行 `stage()` 与 `deliver()`。
   - **解决要求**：
     - 保留 `Source.envelope.spans` 完整内容不动；将笔记缓存独立存为 `memories-cache.json`（同等 `.completeFileProtectionUntilFirstUserAuthentication`），首次无新文件时从 `context.json` 的旧 `memories` 字段无损读取，且不破坏旧结构解码兼容；
     - `uploadSources()` 改为按分页/有限批次检查点写盘（避免每条 `stage`/`deliver` 各全量编码一次 `context.json`），且 `commit` 资料状态时不再重赋 `@Observable var memories`；
     - `prepareSubmission` 若命中后台正在投递的同一 `sessionID` 或并发修改 `state.sources`，必须每次在 `await` 后基于最新内存 `state` 按字段合并单个 `sources[id]`，不得用旧快照整体覆盖后台已推进的 `receipt` 或 `deliveredChangeRevision`。

3. **【阻塞点 3：`PhoneRemoteAgent` 多触发源汇流与取消代次清理边界】**
   - **源码位置与触发条件**：保留双 `NWPathMonitor` 分工的前提下，当前 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L191-L216)（`reconnect`）、第 246–260 行（`foreground` 固定 2.5 秒超时后无条件启动 `health`/`sources`/`notifications`/`lifeIllustrations` 轮询）与第 346–357 行（`pathUpdateHandler` 不看 `connecting` 直接并发触发刷新）仍是三条各自为政的恢复流；且 [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L133) 在 `inFlight` 刚被 `background()` 取消但尚未跑完 `defer` 时，回前台新调用会 `await` 该已取消任务直接拿到 `CancellationError`。
   - **解决要求**：三处入口统一汇入同一 `(connectionIdentity, sceneGeneration)` 协调方法；聊天与可见笔记立即并行恢复，非紧急同步（上传、Health、Sources、Notifications、插画轮询）改由当前代次首次真实已鉴权响应（而非固定 2.5 秒定时器）放行；任务取消立即推进本域请求代次，新请求绝不复用 `isCancelled` 的旧 `Task`。

---

## 三、原方案最小完整修订建议（仅限首轮 `P0–P2`）

只需对 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md) 做以下 4 处增量修订即可冻结首轮设计并动工：

1. **第 4 节（第 86–97 行，错误分类与鉴权边界）**：
   - 写明保留 `100.64.0.0/10` CIDR ATS 例外；将 `-1022`、TLS 错误移出 `isSocketOrLinkFailure`，同时在已验证端点/SOCKS5 代理上下文保留 `.badURL` 有界连接池修复兼容（覆盖带与不带 underlying error 两种测试入口）。
   - 将第 92 行“尝试协议已有的凭据恢复”修正为“现协议无自动凭据刷新；确认来自已绑定通道的业务 401 进入统一 `authenticationRequired` 并停止自动轮询，保留全部缓存与待发操作，支持用户手动重试恢复”。
   - 明确 Mac `DesktopModel` 自检遇 `-1022` 在 `recentlyVerified` 过期后上报检查失败，不报 `reconnecting`。
2. **第 3、4、7 节（第 64–69、82–85、162–166 行，代次与后台预算）**：
   - 明确三层独立代次：`EmbeddedTailnet` 节点 `generation`、连接池/`proxyCheck` 会话代次（`suspendSessions()` 同步取消 `proxyCheck`，取消不置 `needsRestart`）、`PhoneRemoteAgent` 前后台 `sceneGeneration`；纳管 `AgentRTCTransport` 与 `LifeIllustrationStore` 门控。
   - 明确 `PhoneInboxRefresh` / `PhoneContextDelivery` 按系统后台剩余时间收紧单次连接与读取截止时间，并在 `PhoneContextDelivery.expire()` 中先调内层 `cancel()` 再执行 `finish(...)` 释放 OS grant。
3. **第 6 节（第 118–125 行，拆库与录音引用边界）**：
   - 补充：① 笔记缓存独立文件 + 旧字段兼容读取，**保留 `Source.envelope.spans` 不裁剪**以保障 `prepareSubmission` 录音引用与重投完整性；② `applySpeakerCorrections` 留在上传通道前置串行；③ 上传遇瞬时网络错误、429、可重试 5xx 立即终止本轮余下遍历，单条永久错误（如超限）标记可见错误并跳过后续阻塞；④ 上传改为按批检查点写盘，并以 500 条积压实测落盘次数与主线程耗时。
4. **第 10、11 节（第 200–209、232–245 行，测试宿主映射）**：
   - 标注首轮必跑且禁止静默 skip 的四个测试入口：`MoMoAgentClientTests`、`Tests/Support/test-tailnet-recovery.py`、`RemoteContextSyncTests` / `PhoneContextDeliveryTests`（单模拟器默认字号）及现有 Python Runtime 基线测试；将 `P3`（含 `rtc_transport.py:permitted_route` 与 `/context/v1/status` 能力声明）与 `P5` 明确留作后续独立阶段。

完成上述文档微调后，**可直接进入首轮 `P0–P2` 编码实施**，无需第三轮方案空转审查。

当前模型：Gemini 4 Carbon (High)

