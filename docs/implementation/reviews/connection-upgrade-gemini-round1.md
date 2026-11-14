# Gemini 第一轮审查原文（未经事实校正）

日期：2026-11-14。模型：`gemini-4-carbon-high`，effort `high`。
agy 会话：`2a4b7d87-8fc2-4912-90b0-dfeda6f64453`。返回状态 SUCCESS，审查用时约 989 秒。

此文件保留 reviewer 原文，其中存在与源码及 Apple 现行文档矛盾的判断，不能直接作为实施依据。采纳与驳回见 [逐条复核](connection-upgrade-round1-response.md)。

---

# MoMo Agent「Mac–手机连接与同步架构升级方案」严格代码核对与独立审查

- **审查对象**：[mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md)
- **源码基线**：`4af63c1aaa7c047136a0527f531feae67379a209`（与方案第 5 行一致，只读核对）
- **总体结论**：**有条件通过（需修正多项阻塞级方案盲区后再进入实施）**。方案对 ATS 伪 CIDR 例外、`AgentTransportFailure` 过度宽泛、Tailnet 多处抢修与上传阻塞笔记刷新四个表象定位准确，但在对照实际源码后存在 **5 个 P0 级阻塞问题、7 个 P1 级高危缺陷、4 个 P2 级边界与可测性缺口**——若按原方案字面直接编码，会破坏 SOCKS5 冷启动重试、让新增量接口在所有远程通道直接 404、在 WebRTC/Relay 流中断时永久杀死聊天 SSE，并在 500 条积压录音下引发 `@MainActor` 千次全量 JSON 覆写卡死。

---

## 一、P0 / P1 / P2 问题清单（含触发条件、影响、源码行号与采纳建议）

### P0 级（阻塞交付：直接导致连接不可用、新协议全通道 404、冷启动退化或主线程卡死）

#### P0-1 【方案缺陷】将 `URLError.badURL (-1000)` 一刀切归为永久配置错误，会破坏 tsnet SOCKS5 冷启动与 GET 自动重试
- **关注域**：`AgentTransportFailure` 错误分类 / 连接恢复所有权
- **源码证据**：
  - [AgentTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/AgentTransport.swift#L23-L42)：当前把除 `.cancelled` 外的全部 `URLError` 归为 `isSocketOrLinkFailure == true`（**当前代码缺陷**：导致 ATS `-1022`、TLS `-1200…-1206` 等被误判为瞬时链路故障）。
  - [EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L439-L448)、[EmbeddedTailnetTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnetTransport.swift#L67-L74)、[RemoteTaskStore.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RemoteTaskStore.swift#L1415-L1424) 及回归测试 [test-tailnet-recovery.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/Support/test-tailnet-recovery.py#L169-L171)、[test-tailnet-recovery.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/Support/test-tailnet-recovery.py#L443-L455)：Foundation `URLSession` 经本地 SOCKS5 代理遇到 tsnet 5 秒建连截止或底层 `ECONNREFUSED (NSPOSIXErrorDomain 61)` 时，向调用方抛出的顶层错误正是 **`NSURLErrorDomain -1000 (.badURL)`**，真实套接字错误挂在 `userInfo[NSUnderlyingErrorKey]` 或 `_kCFStreamErrorDomainKey` 下。
  - 方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L93-L99) 将 `.badURL` 直接列入 `configurationRejected` 永久配置错误、禁止自动重试与 SOCKS5 重建。
- **触发条件**：手机从后台唤醒或网络切换后首次经 `EmbeddedTailnet` SOCKS5 代理发起只读 GET / `/pair/identity` 请求，tsnet 首跳尚未完成 DERP/打洞，触发 5 秒 SOCKS5 connect cutoff。
- **具体影响**：`EmbeddedTailnetTransport.shouldRetryPreHeaderGET` 与 `EmbeddedTailnet.shouldRepairSession` 不再重试/修复，聊天和笔记直接报错进入永久“配置拒绝”死锁，现有 `test-tailnet-recovery.py` 回归测试直接挂掉。
- **采纳建议**：**修改方案 P1 分类规则**。对 `URLError.badURL (-1000)` 必须先递归检查 `NSError.userInfo[NSUnderlyingErrorKey]` 与 `_kCFStreamErrorDomainKey`：若底层包含 `NSPOSIXErrorDomain` 或 CFStream Socket/SOCKS 错误，归类为 `transientLink`；仅在无底层流错误（或 URL 本身非法）时归类为 `configurationRejected`。严禁把 `-1022 (.appTransportSecurityRequiresSecureConnection)` 放回可重试集合。

#### P0-2 【方案缺陷】P3 新增的记忆增量接口未纳入 `permitted_route` 统一白名单，也选错了 capability 挂载端点
- **关注域**：内容 hash revision 与一致快照 / 已有加密中继和资源预算
- **源码证据**：
  - [rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py#L26-L86)：`permitted_route(method, path)` 是 **HTTPS/Tailnet（[access_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/access_server.py#L123)）、Relay（[relay_access.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/relay_access.py#L159)）、WebRTC（[rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py#L260)）三类通道共用的硬编码白名单**。第 83–84 行 `/context` 仅放行固定集合 `('/v1/status', '/v1/sources', '/v1/source', '/v1/memories', '/v1/health', '/v1/phone-sources', '/v1/summaries')`。
  - [superagent_gateway.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/superagent_gateway.py#L1834-L1883) vs [context_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/context_server.py#L43-L61)：方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L150-L157) 计划在 `/v1/capabilities` 暴露 `memory_manifest_v1`，但 `/v1/capabilities` 由 `superagent_gateway.py` 提供，而 `PhoneContextSync` 独立访问 `context_server.py`（`/context/v1/status`），且 `PhoneContextSync` 根本不持有 `/v1/capabilities` 结果。
  - 同时，WebRTC DataChannel 单请求体上限为 `MAX_FRAME = 32_768`（32 KB，[rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py#L15)、[rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py#L269)），Relay 单响应体上限为 `8 MB`（[RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L109)）。
- **触发条件**：按方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L148-L175) 只改 `context_server.py`、`momo_memory.py`、`ContextClient.swift`、`PhoneContextSync.swift`。
- **具体影响**：手机经 Tailnet、外部 HTTPS、Relay 或 WebRTC 请求 `/context/v1/memories/manifest` 或批量拉取接口时，全部在接入层直接被 `permitted_route` 拦截返回 `404`；若批量 `POST` ID 列表超过 32 KB，WebRTC 通道会因超帧直接丢弃或退回 HTTP。
- **采纳建议**：
  1. 必须在 [rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py#L83-L86) 同步注册新路由及严格 query 校验（参照第 40–48 行 `life-illustrations/manifest` 写法）。
  2. 将 `memory_manifest_v1: true` 同时放入 `GET /context/v1/status` 响应（[context_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/context_server.py#L43-L61)），由 `PhoneContextSync` 直接自洽协商，不跨模块耦合 `/v1/capabilities`。
  3. 批量拉取每批限制 `<= 50` 个 ID（请求体 `< 4 KB`）且服务端单页响应体限制 `<= 1 MB`（附 `next_cursor`），确保兼容 WebRTC 32 KB 请求帧与 Relay 8 MB 响应上限。

#### P0-3 【当前代码缺陷 + 方案遗漏】ATS `-1022` 不仅影响 iPhone，还会让 Mac 自身探测 `100.64.0.0/10` 永久落入 `reconnecting` 并阻断新设备配对邀请
- **关注域**：`AgentTransportFailure` 错误分类 / 连接恢复所有权
- **源码证据**：
  - [Info.plist (Mac)](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/Info.plist#L36-L48)、[Info.plist (iPhone)](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Resources/Info.plist#L45-L57)、[project.yml](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/project.yml#L94-L98)、[project.yml](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/project.yml#L202-L206)：`NSExceptionDomains` 只接受域名，忽略 CIDR 字符串 `"100.64.0.0/10"`；`NSAllowsLocalNetworking` 只覆盖 loopback/RFC1918/link-local，**不覆盖 RFC6598 (`100.64.0.0/10`)**。
  - [DesktopModel.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/DesktopModel.swift#L786-L827) 与 [DesktopModel.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/DesktopModel.swift#L186-L194)：Mac 端每轮状态巡检调用 `TailnetChunkStream.read` 访问 `http://100.x.y.z:8767/pair/identity`。冷启动首轮（`embeddedHealth.verifiedPeerURL == nil`）或 Mac 睡眠唤醒重置 `embeddedHealth = EmbeddedAccessHealth()` 后，ATS 直接抛 `-1022`，Mac 将自身通道状态上报为 `state: "reconnecting"`。
  - [access_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/access_server.py#L206-L216)：生成配对二维码强校验 `state == 'connected'`，否则直接拒绝签发邀请！
  - 此外，[EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L489) 与 [EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L575) 还通过明文 `http://127.0.0.1:<port>/localapi/v0/...` 访问本地 tsnet API（依赖 `NSAllowsLocalNetworking`）。
- **触发条件**：Mac 冷启动或合盖唤醒后处于内置 Tailnet 模式；或手机向 `http://100.x.y.z:8767` 发起任意请求。
- **具体影响**：手机 100% 失败并每 2–15 秒重试风暴；Mac 唤醒后自检永远 `reconnecting`，甚至无法生成新配对二维码。**方案隐患**：方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L101-L108) 在 P1 讨论切换 `NSAllowsArbitraryLoads` 时若删掉 `NSAllowsLocalNetworking` 或未用 `Tests/Support/verify-release-bundle.py` / `verify-mac-beta.py` 校验构建产物，会导致 `localapi` 127.0.0.1 或签名校验受影响。
- **采纳建议**：
  1. **首次交付（P0–P2）直接采用方案选项 2（ATS 配置收敛）而非在首次交付改动自签 TLS/HTTPS 握手机制**：在 [project.yml](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/project.yml#L94-L98)、[project.yml](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/project.yml#L202-L206) 及两端 `Info.plist` 移除无效的 `"100.64.0.0/10"` 伪域名项，保留 `NSAllowsLocalNetworking: true`，并在未切 `*.ts.net` HTTPS 前显式设置受控 ATS 策略（同时在 `TailnetEndpoint.isOrigin` + `EmbeddedTailnetTransport.open` 强制把明文 `http://` 请求封死在 `100.64.0.0/10` + 绑定 SOCKS5 ephemeral `URLSession` 内，任何非 CGNAT 地址拒绝 `http://`，见 [EmbeddedTailnetTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnetTransport.swift#L34-L36)）。
  2. Mac 端 [DesktopModel.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/DesktopModel.swift#L797) 遇到非瞬时 ATS/配置错误时必须直接报明确错误，不得伪装为 `reconnecting`。

#### P0-4 【当前代码缺陷 + 方案缺陷】`PhoneContextSync` 上传失败不中断循环 + 单文件全量 `context.json` 在 `@MainActor` 同步编码落盘，500 条积压仍会阻塞网络与卡死主线程
- **关注域**：笔记下载与上传解耦及 `State` 提交
- **源码证据**：
  - **代码缺陷 1（串行排队 + 重复跑全量上传）**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L131-L156) 中，`refresh()`（`includeMemories: true`）遇到正在执行的后台 `synchronize(includeMemories: false)` 时，在第 133 行 `if let inFlight { return try await inFlight.value }` 阻塞等待整轮上传结束，随后因 `syncRequested == true` 在第 142 行**再跑一遍完整的 `synchronizeArchive`**（含 `contextStatus` + `uploadSources`）才到第 350 行执行 `downloadMemories()`；且第 334 行 `client.contextStatus()` 未包裹 `try/catch`，一旦超时直接跳过 `downloadMemories()`。
  - **代码缺陷 2（断网时 500 次连续 30 秒超时风暴）**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L432-L441) 遍历 `pendingIDs` 逐条 `deliver(source)`，捕获非 401 网络错误后**不 `break`**，500 条未送达录音会连续发起 500 次请求（每次最长 30 秒超时）！
  - **方案缺陷（只拆网络并发、未拆 `context.json` 持久化与 `@MainActor` 全量序列化）**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L42-L66) 将**所有历史已同步录音的完整 `SourceEnvelope`（含全部 `spans` 转写正文，见 [ContextClient.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/ContextClient.swift#L15-L35)，确认送达后从未裁剪 `spans`！）**与**全部 `memories` 正文**存在同一个 `context.json`。每条录音 `stage()`（第 289/297/315 行）与 `deliver()`（第 324 行）都在 `@MainActor` 同步调用 `commit(_:)`（第 461–466 行）全量 `JSONEncoder().encode` + `.atomic` 写盘，并无条件重赋 `@Observable var memories`（第 464 行）触发 SwiftUI 视图重刷。500 条积压录音会产生 **最多 1,000 次主线程全量多 MB JSON 编码与原子写盘**！
  - **代码并发漏洞**：聊天发送路径 `prepareSubmission`（[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L235-L273)，由 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L451-L453) 调用）绕过 `inFlight` 直接并发调用 `stage()` / `deliver()`。
- **触发条件**：离线录制一天积累数十至 500 条录音后回到前台打开「记忆」页或发送聊天消息。
- **具体影响**：即使按方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L132-L144) 把 `downloadMemories()` 与 `uploadSources()` 拆成两个 `Task`，`uploadSources()` 的主线程千次全量 `commit` 仍会把 UI 卡死并不断触发 `memories` 观察通知；断网时 500 条逐条重试仍会打满连接池。
- **采纳建议**：
  1. **物理拆分存储文件**：将 `memories` 缓存拆到独立文件（如 `memories-cache.json`），与上传队列 `context.json` 彻底隔离，消除跨通道覆写竞争和无谓的 `@Observable memories` 重刷。
  2. **裁剪已送达 `Source` 载荷 + 批量合并落盘**：`deliver()` 拿到 `receipt` 后，本地只需保留 `(sourceID, version, generation, textSha256, recordedAt, deleted, receipt)` 元数据用于幂等去重，立即清空已送达条目的内存/磁盘 `spans` 大文本；`stage` 分页与 `deliver` 每批合并写盘（而非逐条写全库），编码放到后台或轻量结构。
  3. **上传遇瞬时传输错误立即短路（break）**：`uploadSources()` 在 `deliver(source)` 遇到 `AgentTransportFailure.isTransient(error)` 时立即停止本轮剩余条目并交还退避调度，严禁对剩余 499 条继续轰炸。
  4. **独立状态属性**：拆分 `isRefreshingMemories` 与 `isUploadingSources`（保留计算属性兼容现有视图或明确把 [RemoteMemoryView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift#L112) 和第 318 行绑定到 `isRefreshingMemories`），并在 `downloadMemories()` 旁附带轻量获取 `memoryReview` 状态（否则解耦后 [RemoteMemoryView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift#L313) 的「正在整理…」状态在无上传时永远不更新）。

#### P0-5 【方案缺陷 + 当前代码缺陷】Mac 端记忆读取无一致锁保护，存在跨目录写入竞态，会导致 P3 增量缓存永久漏同步
- **关注域**：内容 hash revision 与一致快照
- **源码证据**：
  - [momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L166-L172) 写笔记本持 `.notebooks.lock`；[momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L357-L370) 写 `MEMORY.md`/`USER.md` 持各自 `.md.lock`；但读路径 `MoMoMemory.list()` / `items()` / `store()`（[momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L645-L654)、[momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L757-L796)）**完全不加任何文件锁**！
  - 同时，SuperAgent 运行时（[superagent_gateway.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/superagent_gateway.py#L2344-L2382)、第 4357–4410 行）与 `momo_cli.py`（第 216–236 行）在独立进程/线程中并发读写 `memories/` 多级目录。
  - 更严重的是，当前分页快照键为 `(len(items), max(updated_at))`（[momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py#L783)）：若一篇旧笔记被删除同时新增一篇笔记且时间戳未超过历史最大值，或同一秒内两次编辑（文件系统精度/外部编辑器保留 mtime），`revision` 完全碰撞。
- **触发条件**：SuperAgent `Dream` 或对话 `notebook` 工具正在多步写入/移动 `memories/` 下多篇笔记时，手机并发拉取 `manifest` 与 `batch`。
- **具体影响**：若仅按方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L158-L169) 计算全量文件 SHA-256 而不统一读写快照锁，读线程会扫描到半提交的多文件目录状态（例如 `move_notebook` 删旧建新中间态），且每次 `manifest` 请求若在 `memories/` 含数百个文件时无缓存重读全部文件内容算 SHA-256，会造成不必要的磁盘抖动。
- **采纳建议**：
  1. 在 `MoMoMemory` 统一快照锁（或将读取快照纳入 `.notebooks.lock` 共享锁 `LOCK_SH`、写入用 `LOCK_EX`，并覆盖 `BRIEFING.md`/`MEMORY.md`/`USER.md` 原子 rename）。
  2. 服务端按文件 `(relative_path, st_mtime_ns, st_size)` 做进程内轻量缓存映射到 `content_sha256`（仅在 `mtime_ns` 或 `size` 变化时重读文件计算 SHA-256），既防 mtime 碰撞又避免每次 `manifest` 全盘读正文；顶层 `snapshot_revision` 由排序后的 `(id, content_sha256)` 列表再做一次 SHA-256 生成。

---

### P1 级（高危缺陷：引发 SSE 假死、重连惊群、后台挂起崩溃或永久鉴权锁死）

#### P1-1 【当前代码缺陷 + 方案遗漏】`RelayError.protocolFailure` 被标为非瞬时错误，WebSocket 正常重连/空闲断开会永久杀死聊天 SSE 订阅
- **关注域**：`AgentTransportFailure` 错误分类 / 已有加密中继和资源预算 / 持久游标和幂等
- **源码证据**：
  - [RelayCipher.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayCipher.swift#L87-L98)：`RelayError.protocolFailure` 的 `isTransientTransportFailure` 为 `false`。
  - [RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L81) 与 [RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L108)：当底层 `URLSessionWebSocketTask` 收到服务端/中继关闭帧或非二进制控制消息时，`guard case .data(let data) = ... else { throw RelayError.protocolFailure }` 直接抛 `.protocolFailure`；且第 108 行 `readBody` 对流式 SSE 也设了固定 75 秒 `receive` 超时。
  - [ConversationSubscription.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/ConversationSubscription.swift#L97-L99)：`guard !Task.isCancelled, AgentTransportFailure.isTransient(failure) else { return }`——一旦判定非瞬时错误，**直接退出 `run()` 订阅循环，不再重连**！
- **触发条件**：手机使用 Relay 模式连接 Mac，中继节点重启、NAT 切换或返回文本关闭帧。
- **具体影响**：聊天 SSE 订阅静默永久终止，除非用户切后台再切回前台，否则再也收不到流式回复与已读状态。
- **采纳建议**：在 `RelayError` 中将握手后的 WebSocket 帧中断（如 `.connectionClosed`）与真正不可恢复的加密篡改/重放（`.tamperedOrHandshakeFailed`）拆开：握手确认失败或 GCM 验签失败在单次连接上作废会话但允许新建 WebSocket 重握（除非配对码格式非法 `.invalidConfiguration`），避免杀死 `ConversationSubscription`。

#### P1-2 【方案缺陷】连接协调器漏管 `AgentRTCTransport`、双 `NWPathMonitor` 与 `LifeIllustrationStore`，且前台 2.5 秒超时后仍放行惊群
- **关注域**：连接恢复所有权
- **源码证据**：
  - 双 `NWPathMonitor` 并存且各自触发重连：[EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L332-L362) 与 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L338-L360)。
  - 方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L64-L78) 只列举了 Tailnet、聊天、Context、通知、Health、Sources，**完全漏掉了两块活跃网络组件**：
    1. `connection.network == nil`（外部 HTTPS 模式）时启用的 WebRTC 数据通道 [AgentRTCTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentRTC/AgentRTCTransport.swift#L139-L158)（由 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L419) 创建）；
    2. 每 15 秒独立轮询 + 4 路并发下载资源的 [LifeIllustrationStore.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/LifeIllustrationStore.swift#L74-L82) 与第 180 行！
  - 此外，[PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L246-L256) 中 `waitForConnectionReady(timeout: .milliseconds(2500))` 最多只等 2.5 秒（而 Tailnet 冷恢复预算 `startupTimeout 15s + peerMapTimeout 12s = 27s`，见 [EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L62-L65)），2.5 秒一到无论通道是否就绪，5 个业务模块 + `LifeIllustrationStore` 立即同时冲向 `connectedSession`！
- **触发条件**：冷启动或 Wi‑Fi/蜂窝切换，Tailnet 打洞耗时 > 2.5 秒（常见 3–8 秒）。
- **具体影响**：6 个模块同时穿透等待门栓，产生并发建连与重复探活风暴。
- **采纳建议**：
  1. 删除 `PhoneRemoteAgent` 的第二个 `NWPathMonitor` 或统一由单一路径监听器向协调器投递事件（带 300–500ms 去抖）。
  2. 将 `AgentRTCTransport` 与 `LifeIllustrationStore` 显式纳入协调器生命周期门控。
  3. 协调器未进入 `ready` 前，**禁止因 2.5 秒超时而盲目放行非紧急轮询模块**（`Health`、`Sources`、`Notifications`、`LifeIllustrations`、`uploadSources` 均须订阅协调器的 `ready` 状态边沿触发；仅本地缓存读取立即渲染 UI，绝不阻塞首屏）。

#### P1-3 【方案缺陷 + 当前代码缺陷】方案假设“401 尝试协议已有的凭据恢复”，但服务端根本不存在凭据刷新协议，且现有 `authenticationRequired` 置位后存在单向死锁
- **关注域**：`AgentTransportFailure` 错误分类 / 连接恢复所有权
- **源码证据**：
  - 方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L92) 写道：「`401`、明确撤销或凭据失效 → 尝试协议已有的凭据恢复；仍失败则进入 `authenticationRequired`」。
  - 核对 [access_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/access_server.py#L103-L108)、`pairing_store.py` 与 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L436-L440)：**代码库中根本没有 token refresh / 凭据自动恢复协议**，设备 Bearer token 只有配对签发与撤销两种终态。
  - 同时，当前代码有两套割裂的鉴权死锁位：`RemoteTaskStore.connectionState = .authenticationRequired`（令 `canContactServer == false`，[RemoteTaskStore.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RemoteTaskStore.swift#L83)）与 `PhoneContextSync.authenticationRequired = true`（[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L31)、第 130/163 行，**一旦置 `true` 在实例生命周期内永不复位**）。若外部反向代理在网关重启瞬间误返一次非 MoMo JSON 的 `401`（如 Cloudflare/Nginx 401 HTML），整台手机会永久锁死所有同步，连下拉刷新都直接抛 `CancellationError()`！
- **触发条件**：外部网关瞬时返回非业务 401，或按方案寻找不存在的“凭据恢复接口”。
- **具体影响**：误把网关 401 当作设备撤销永久锁死客户端；实现者按方案编码时无从下手。
- **采纳建议**：删掉方案中“尝试协议已有的凭据恢复”的虚假前提。严格区分**经签名的 MoMo 接入层 401 / `/pair/identity` 确认撤销**与外部代理网关异常：收到业务请求 401 时，协调器通过单飞做一次带 Bearer 的 `/v1/capabilities` 复核；确认仍为 401 后才统一进入 `authenticationRequired` 并提示重新配对；否则按网关瞬时错误退避。统一由协调器持有鉴权状态，删除 `PhoneContextSync` 孤立不可复位的布尔锁。

#### P1-4 【当前代码缺陷 + 方案缺陷】前后台切换存在 3 处代次（Generation）混淆与取消竞争，会导致回前台复用已取消任务或误触发 Tailnet 整节点重建
- **关注域**：前后台代次与取消竞争
- **源码证据**：
  1. **`EmbeddedTailnet` 挂起未取消 `proxyCheck` 且共用节点代次**：[EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L373-L383) 中 `suspendSessions()` 使 `URLSession` 失效但**既没有取消 `proxyCheck`（第 33、561–607 行），也没有递增会话代次**。若切后台瞬间 `checkProxyIfNeeded()` 正在跑，会话被 `invalidateAndCancel()` 杀掉后第 598 行 `self?.generation == attempt` 仍成立，误置 `needsRestart = true`，导致下次切回前台把整个底层 Go Tailscale 节点 `close()` 重建（耗时数秒至十余秒）！反之，若按方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L68) 在每次前后台切换都递增同一个 `EmbeddedTailnet.generation`，则会把后台 IPN 监听循环 `ensureWatchRunning` 与 `startPathMonitor`（第 324、341 行检查 `self.generation == attempt`）直接误杀！
  2. **`PhoneContextDelivery.expire()` 先调 `finish` 再 `cancel`，抢先关闭共享传输**：[PhoneContextDelivery.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextDelivery.swift#L95-L101) 在后台配额到期时先调 `finish(...)`（内部立即令 `isActive = false` 并触发 `suspendTransportIfIdle()` 销毁 `URLSession`），第 100 行才 `task?.cancel()`，且此时若 `replyContinuation.isActive` 刚结束或切换中，未清理完的任务会产生悬挂错误写入 `sourceDeliveryFailure`。
  3. **快速切后台再切回前台复用已取消的 `inFlight`**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L103) `background()` 调用 `inFlight?.cancel()` 但不置空 `inFlight`（等 `defer` 第 158 行）；若用户 100ms 内滑回前台触发 `foreground()` -> `synchronize()`，第 133 行 `if let inFlight { return try await inFlight.value }` 会直接挂到那个**已被取消的旧任务**上并收到 `CancellationError`，导致回前台首轮同步直接静默丢失！
- **触发条件**：快速前后台切换（如拉下控制中心/通知中心或 App 间快速切回），或后台续传超时瞬间。
- **具体影响**：回前台首轮笔记/转录不刷新，或 Tailnet 节点无故全量重启断联 10+ 秒。
- **采纳建议**：**明确拆分三层 Generation，不得混用同一个计数器**：
  - `nodeGeneration`（`EmbeddedTailnet` Go 节点生命周期，仅在 `close()`/身份变更时递增）；
  - `sessionGeneration`（`EmbeddedTailnet` URLSession/SOCKS5 会话周期，`suspendSessions()` 时递增并立即取消 `proxyCheck`）；
  - `sceneGeneration`（`PhoneRemoteAgent` 前后台周期）。
  同时修正 `PhoneContextSync`：取消旧 `inFlight` 时必须记录任务 token 或新开代次，新 `synchronize()` 绝不能 `await` 已被 `isCancelled` 的旧 `Task`。

#### P1-5 【方案缺陷】聊天持久游标缺失服务端裁剪边界测试与 `409 event_cursor_invalid` 期间未送达消息的顺序保障校核
- **关注域**：持久游标和幂等
- **源码证据**：
  - [conversation_events.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/conversation_events.py#L35-L38) 与 [conversation_events.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/conversation_events.py#L62)：`conversation_events` 表在每次 run 结束时只删除瞬态 `message.delta`/`message.interim`，保留结构化事件；第 62 行仅在 `cursor < 0` 或 `cursor > self.cursor`（例如服务端重建了 `conversation.sqlite` 导致 `self.cursor` 回退小于客户端持久化的 `eventCursor`）时返回 `HTTP 409 (event_cursor_invalid)`。
  - [RemoteTaskStore.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RemoteTaskStore.swift#L502-L535)：客户端收到 `409` 后调用 `bootstrapConversationSnapshot()` 拉取 `GET /momo/v1/conversation/snapshot`。
  - **隐藏风险**：[superagent_gateway.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/superagent_gateway.py#L3880-L3888) 中 `live_snapshot()` 调用 `self.store.page(before=top + 1)` 默认只返回**最新 100 条消息**（[conversation_store.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/conversation_store.py#L354) `limit=100`），而 `conversation_events` 表长期运行**没有任何行数/时间上限裁剪**（除 delta 外无限增长）！
- **触发条件**：
  1. 长期高频使用数月后，`conversation_events` 无限膨胀；若离线期间产生 >100 条事件/消息后发生游标重置（409），`snapshot` 只覆盖最新 100 条。
  2. Mac 重置数据库但保留配对身份时，客户端本地缓存的旧消息 `seq` 与新库 `seq` 冲突。
- **具体影响**：`conversation.sqlite` 体积持续膨胀；游标失效回退 `snapshot` 时若未校核 `conversation_id` 或消息分页缺口，可能残留旧实例幽灵消息或丢失超过 100 条边界的同步提示。
- **采纳建议**：
  1. 在 P4 明确：`conversation_events` 若新增按时间/条数保留窗口（例如保留最近 7 天或 50,000 条，记录 `min_retained_cursor`），`subscribe` 当 `0 < after < min_retained_cursor` 时同样返回 `409 event_cursor_invalid` 触发 `snapshot` 追平（注意 `after=0` 且客户端无游标时走首次 `snapshot` 再 `subscribe(after=snapshot.cursor)`）。
  2. 核对幂等保证：[conversation_store.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Runtime/conversation_store.py#L248-L250) 注释明确 `inputs` 表**永不裁剪**（尽管 `MESSAGE_RETENTION_SECONDS = 86400` 用于对外宣告最小保证窗口），切勿在实施 P4 时误给 `inputs` 加 24 小时删除任务破坏跨天离线重发幂等。

#### P1-6 【方案缺陷】忽略 iOS 后台 `BGAppRefreshTask` / 静默推送 22–30 秒硬预算与 Tailnet 27 秒冷启动超时之间的预算倒挂
- **关注域**：iOS 后台限制
- **源码证据**：
  - [PhoneAppDelegate.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Bootstrap/PhoneAppDelegate.swift#L97-L110)：`PhoneInboxRefresh.fetch`（供 `BGAppRefreshTask` 与 APNs `didReceiveRemoteNotification` 共用）设有 **22 秒硬超时**。
  - [PhoneContextDelivery.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextDelivery.swift#L29)：UIKit 后台延续任务预算为 **25 秒**。
  - 但 [EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L62-L65) 的 `startupTimeout (15s) + peerMapTimeout (12s) = 27s`，加上 `AgentClient` 单次请求默认 30 秒超时，**单次 Tailnet 冷唤醒预算（27s+30s）已经超过 iOS 后台任务总寿命（22–25s）**！
  - 此外，核对文件保护属性：当前代码（[PhoneComposition.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Bootstrap/PhoneComposition.swift#L25)、[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L462)、[PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L100)）已统一使用 `.completeUntilFirstUserAuthentication`。若按 P0-4 拆分新的 `memories-cache.json` 或同步游标文件而漏写 `.completeFileProtectionUntilFirstUserAuthentication`，锁屏后台唤醒时读写新文件会直接抛 `NSFileReadNoPermissionError`！
- **触发条件**：iPhone 锁屏挂起期间收到静默推送或 `BGAppRefreshTask` 唤醒，且采用内置 Tailnet 连接。
- **具体影响**：22 秒预算耗尽在等待 Tailnet 节点唤醒或单次 30 秒请求超时上，`PhoneInboxRefresh` 取消退出后未及时挂起刚拉起的半连接会话。
- **采纳建议**：
  1. 为后台唤醒模式（`backgroundRefresh` / `contextDelivery`）向协调器传入显式 deadline（如建连上限 `<= 10s`、单请求 `timeoutInterval <= 8s`），超时立即失败并在 `defer` 中同步调用 `suspendTransportIfIdle()`，绝不后台自旋重试。
  2. 所有新增缓存文件强制显式带 `[.atomic, .completeFileProtectionUntilFirstUserAuthentication]`，并在首次解锁前（`UIApplication.shared.isProtectedDataAvailable == false`）静默跳过后台启动。

#### P1-7 【方案缺陷】P5 加密中继并发与体积限制未对齐现有 `RelayTransport` 串行锁与 8 MB 硬上限
- **关注域**：已有加密中继和资源预算
- **源码证据**：
  - [RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L46-L98) 与 [relay_access.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/relay_access.py#L99-L148)：**每次 `RelayTransport.open(request)` 都会新建一条独立的加密 WebSocket 连接并执行完整 ECDH + HKDF 握手**（`URLSession.webSocketTask(with: room)`），并非多路复用单条 WebSocket！而 Mac 端 `RelayTunnel` 虽然在单条 Responder WebSocket 上按 `cid` 转发，但每个客户端请求都要经历一次端到端握手往返。
  - 同时：[relay_access.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/relay_access.py#L162) 限制请求体 `<= 512 KB`；[RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L109) 限制响应体 `<= 8 MB`。
  - 方案 [mac-phone-connection-upgrade-20261114.md](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/docs/plan/mac-phone-connection-upgrade-20261114.md#L197-L209) 笼统提出“评估在 Tailnet 打洞超时时自动回退到已配对的加密中继”，却忽略了两个事实：
    1. [PairingClient.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/PairingClient.swift#L29-L35) 与 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift#L410-L416) 中，Tailnet 配对连接的 `relayCode == nil`（`guard value.relayCode == nil`），而 Relay 连接设置 `requiresExclusiveRouting == true`（[RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L18)）；**当前协议里同一条 `AgentConnection` 根本没有同时携带 Tailnet endpoint 和 `relay_code`！**
    2. Mac 端 [access_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/access_server.py) 与 `tunnel.py` 同一时刻只激活一种 `mode`（`tailscale` **或** `relay` **或** `external`），Mac 并未同时运行 Tailscale 与 Relay Responder！
- **触发条件**：试图在不改 Mac 端双通道同时在线与配对载荷扩展的前提下实现 P5“Tailnet 超时自动回退加密中继”。
- **具体影响**：架构前提不成立——Mac 在 `tailscale` 模式下根本没有连接 Relay 房间，手机也没有 `relay_code` 可回退；且若在 Relay 模式下放任 `LifeIllustrationStore`（4 并发）+ 聊天 SSE + Context 并发请求，会瞬间向中继服务器发起近 10 条并发 WebSocket 握手，触发中继限流或抢占。
- **采纳建议**：P5 **严禁混入首次交付**；在 Relay 模式下客户端协调器还应限制非聊天后台同步并发度（如资源下载并发从 4 降为 1–2）。（P5 必检前置条件详见下文第三节。）

---

### P2 级（体验一致性、可观测性与测试可执行性缺口）

#### P2-1 【当前代码缺陷 + 方案细节】记忆页状态文案无视真实调度状态，硬编码显示「稍后自动重试」
- **关注域**：笔记下载与上传解耦及 `State` 提交
- **源码证据**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L146-L147) 对所有 `isTransient(error)` 一律赋值 `"笔记暂未刷新，稍后自动重试。"`；[RemoteMemoryView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift#L93-L99) 与第 323–329 行直接渲染 `sync.failure`，哪怕 `polling == nil`（无自动重试定时器）或协调器已因离线挂起重试。
- **采纳建议**：采纳方案第 9 节，令 `PhoneContextSync` 暴露结构化同步状态（`idle` / `refreshing` / `scheduledRetry(nextAttemptAt)` / `pausedForConnectivity` / `actionRequired(message)`），仅当协调器或轮询确有下次重试计划时才展示「稍后自动重试」。

#### P2-2 【方案缺陷】测试矩阵中模块边界不可直接编译执行：`MoMoAgentClientTests` 无法测试 `EmbeddedTailnet` 与 `PhoneRemoteAgent`
- **关注域**：测试可执行性
- **源码证据**：
  - [Package.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Package.swift#L14-L20)：`MoMoAgentClientTests` 仅依赖纯协议包 `MoMoAgentClient`（连同包的 `MoMoAgentRTC` 都未引入 `MoMoAgentClientTests`！）。
  - 而 `EmbeddedTailnet` / `EmbeddedTailnetTransport` 位于应用共享源码目录 `Apps/ClientUI/Network/`，`PhoneRemoteAgent` / `PhoneContextSync` 位于 `Apps/iPhoneApp/`（由 `Tests/iPhoneIntegrationTests` 通过 `@testable import MoMoAgent` 测试，见 [RemoteContextSyncTests.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/iPhoneIntegrationTests/RemoteContextSyncTests.swift#L6)），Tailnet SOCKS5 恢复逻辑则由独立编译探针脚本 [test-tailnet-recovery.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/Support/test-tailnet-recovery.py#L1-L45) 执行。
  - 此外，[RelayTests.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Tests/MoMoAgentClientTests/RelayTests.swift#L75-L77) 中端到端中继测试依赖环境变量 `MOMO_RELAY_FIXTURE`，默认 `swift test` 会直接 `XCTSkip`！
- **触发条件**：按方案第 11 节编写单测/集成测试。
- **具体影响**：若把协调器或 Tailnet 单飞测试放错 target 会无法编译，或因 `XCTSkip` 误以为 Relay 流恢复已通过验证。
- **采纳建议**：在方案第 11 节明确每个测试用例的真实宿主 Target：
  - `AgentTransportFailure`（含 `-1022` vs SOCKS5 `-1000+POSIX`、`RelayError`、`AgentRTCError`）→ `MoMoAgentClientTests`（并为 `MoMoAgentRTC` 补测试依赖或独立 `MoMoAgentRTCTests`）；
  - `EmbeddedTailnet` 单飞、前后台 `sessionGeneration` 与 `proxyCheck` 取消 → [test-tailnet-recovery.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Tests/Support/test-tailnet-recovery.py)；
  - `PhoneRemoteAgent` 协调器、`PhoneContextSync` 拆库与 500 条录音积压不卡主线程 → `Tests/iPhoneIntegrationTests/RemoteContextSyncTests.swift`（模拟器单设备运行，遵守单模拟器规则）；
  - `permitted_route` 新白名单、文件锁快照与 `memory_manifest_v1` → `Tests/AgentRuntime/test_momo_memory.py` + `Tests/AgentRuntime/test_webrtc.py` + `Tests/AgentRuntime/test_relay_access.py`。

#### P2-3 【当前代码缺陷】单条超大录音转写（如全天数小时会话）在 Relay / WebRTC 下可能触碰请求体上限而永久卡在待上传队列
- **关注域**：已有加密中继和资源预算 / 笔记下载与上传解耦
- **源码证据**：[PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift#L305-L315) 将单个会话全部 `spans` 打包进一次 `POST /context/v1/sources`；而 [relay_access.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/relay_access.py#L162) 限制单次请求体 `<= 512 KB`（[RelayTests.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Tests/MoMoAgentClientTests/RelayTests.swift#L43-L45) 抛 `RelayError.requestTooLarge`，`isTransient == false`）。
- **触发条件**：全天长录音单个 session 累积超过 ~15 万汉字/数千个 `Span`（JSON > 512 KB），且通过 Relay 连接同步。
- **具体影响**：该条 `deliver(source)` 永久抛 `RelayError.requestTooLarge`，且连带令 `deliveredChangeRevision` 永远无法追平 `sourceChangeRevision`，导致后台 `needsDelivery` 永远为 `true`！
- **采纳建议**：在 `uploadSources()` 中将 `.requestTooLarge` / HTTP `413` 标记为该单条 `source` 的不可重试隔离错误（记录局部失败状态，不阻塞后续正常录音送达，也不让 `needsDelivery` 在后台无限空转申请 `BGTask`）。

#### P2-4 【方案缺陷】日志诊断指标需严守隐私红线，禁止记录 `relay_code`、Bearer token 或完整 URL query
- **关注域**：连接恢复所有权 / 安全边界
- **源码证据**：[EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift#L19) 已使用 `OSLog`；方案第 3 节（第 75–77 行）要求暴露 `lastFailureKind`、`lastHandshakeDurationMs` 等诊断字段。
- **采纳建议**：诊断结构只记录脱敏枚举（通道类型 `tailscale`/`relay`/`https`/`webrtc`、错误分类、`NSError.domain + code`、耗时毫秒、代次号），严禁拼入 `relayCode`、完整 `URLRequest` headers 或转录/记忆内容。

---

## 二、交付范围裁定：首次交付（P0–P2）、P3 取舍与 P5 前置条件

### 1. 哪些修改必须作为首次交付（`P0–P2`）闭环落地？
以下 6 项互为因果，**缺一不可，必须同批作为首次交付落地**：
1. **ATS 合法化修复 + Mac 自检去误报**（修复 P0-3）：清理 `project.yml` 与两端 `Info.plist` 中无效的 `"100.64.0.0/10"` `NSExceptionDomains`；保留 `NSAllowsLocalNetworking` 并配置受控 ATS 策略 + 代码层 `TailnetEndpoint.isOrigin` CGNAT 强校验；修复 `DesktopModel` 把 ATS/配置拒绝误报为 `reconnecting` 的问题。
2. **`AgentTransportFailure` 精确错误分类**（修复 P0-1、P1-1、P1-3）：
   - `-1022`、TLS 证书错误、URL 格式错误归为 `configurationRejected`（不重试、不重建 SOCKS5）；
   - **特判 `URLError.badURL (-1000)`**：检查 `NSUnderlyingErrorKey` / CFStream 底层 POSIX 错误，保留 tsnet SOCKS5 冷建连与 pre-header GET 重试能力；
   - 拆分 `RelayError` 帧断开（可重连）与篡改/配置错误，修复聊天 SSE 假死；
   - 401 经单飞 `/v1/capabilities` 复核后统一置位协调器 `authenticationRequired`，删除不存在的“凭据自动恢复”假设及 `PhoneContextSync` 孤立死锁布尔位。
3. **三层代次拆分与单飞连接门控**（修复 P1-2、P1-4）：
   - 区分 `nodeGeneration`、`sessionGeneration`、`sceneGeneration`；
   - `EmbeddedTailnet.suspendSessions()` 递增 `sessionGeneration` 并取消 `proxyCheck`，防止误置 `needsRestart = true`；
   - 收敛双 `NWPathMonitor` 为单一路径源；把 `AgentRTCTransport` 与 `LifeIllustrationStore` 一并纳入 `PhoneRemoteAgent` 连接门控，消除 2.5 秒超时后的惊群放行。
4. **`PhoneContextSync` 读写通道物理拆库 + 短路退避**（修复 P0-4、P2-1、P2-3）：
   - 将 `memories-cache.json` 与上传队列 `context.json` 拆成两个独立文件（均带 `.completeFileProtectionUntilFirstUserAuthentication`）；
   - 已拿到 `receipt` 的历史 `Source` 立即释放本地 `spans` 大文本，批量合并落盘，彻底消除 `@MainActor` 千次全量 JSON 覆写；
   - `downloadMemories()` 与 `uploadSources()` 独立运行、独立状态（`isRefreshingMemories` vs `isUploadingSources`）；`uploadSources()` 遇到瞬时传输错误立即 `break` 短路；修正「稍后自动重试」诚实状态展示。
5. **iOS 后台短预算防倒挂**（修复 P1-6）：后台 `PhoneInboxRefresh` / `PhoneContextDelivery` 传入短建连与请求超时上限（`<= 8–10s`），退出或超时严格先取消任务、再释放传输会话。
6. **P4 聊天游标与幂等契约回归校核**（修复 P1-5）：保留现有 `ConversationSubscription` + `ProductStore` 成熟实现，补齐 `conversation_id` 变更清理与 `409 event_cursor_invalid` 快照追平测试，**不改写现有聊天传输模型**。

### 2. `P3`（记忆增量 Manifest 同步）是否应与 `P0–P2` 同时做？
**明确建议：不要绑进首次交付 PR，应紧随 `P0–P2` 稳定后作为第二阶段独立 PR 交付。**

理由如下（基于源码事实）：
- 当前记忆同步慢与失败的核心瓶颈 **95% 来自 ATS `-1022` 死循环、`uploadSources()` 串行阻塞（含 500 次 30 秒超时不 `break`）以及 `context.json` 主线程全量编码写盘**，而非 `GET /context/v1/memories` 本身的网络字节数（几百条 Markdown 笔记经 gzip 后通常仅数十至数百 KB）。
- `P3` 横跨 **Mac 文件锁改造（`momo_memory.py`）、`context_server.py` 新路由、接入层四通道白名单 `rtc_transport.py:permitted_route`、新旧双端版本兼容回退**。若与连接层重构绑在同一 PR，一旦出现笔记漏更，难以快速二分是连接代次取消问题还是增量快照锁问题。
- **唯一例外**：如果真实用户已经出现总笔记 Markdown **接近或超过 8 MB**（触碰 `RelayTransport` 与 `RTCTransport` 的 `MAX_RESPONSE = 8 MB` 硬上限），则必须在紧随其后的第二个提交立即落地 `P3`。

### 3. `P5`（加密中继回退与传输评估）有哪些必须先验证的前置条件？
在写任何 P5 自动回退代码前，必须先逐项验证并补齐以下 **5 个硬性前置条件**（当前源码均不具备）：
1. **Mac 双通道并发在线能力验证**：当前 `Apps/MacApp/Access/tunnel.py` 与 `access_server.py` 同一时刻只运行单一 `mode`（`tailscale` 与 `relay` 互斥）。必须先验证 Mac 能否在开启 `tailscale` 的同时常驻连接 `RelayTunnel` Responder 且不引发状态机、配对二维码与健康检查冲突。
2. **配对载荷与向后兼容扩展**：当前 `PairingInvitation`（[PairingClient.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/PairingClient.swift#L29-L35)）禁止 Tailnet 邀请携带 `relay_code`。必须设计在不破坏旧版二维码与已配对设备的前提下，如何安全下发并轮换备用中继端到端密钥 `relay_code`。
3. **中继建连模型与并发连接预算实测**：当前 [RelayTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayTransport.swift#L46-L98) **每发起一个 HTTP 请求就新建一条独立 WebSocket 并重跑 ECDH 握手**。必须实测中继服务端（`alma-relay`）在 SSE 常驻 + 笔记/插画/转录同步并发新建多条 WebSocket 时的连接数上限、握手延迟与踢线（preemption）行为。
4. **单请求 512 KB / 单响应 8 MB 上限影响核对**：验证大附件发送、长录音 `SourceEnvelope` 上传及全量笔记同步在中继通道下的分片或降级行为。
5. **无明文降级与身份防串线安全审计**：验证自动从 Tailnet 切往 Relay 时，绝不向非配对房间泄露 Bearer token，且 `workspace_id` / `instance_id` 不匹配时立即熔断。

---

## 三、建议的最小但完整实现顺序（遵循最简工程改动原则）

不新建多余的抽象协议层，直接复用并收敛现有 `PhoneRemoteAgent`、`EmbeddedTailnet`、`AgentTransportFailure` 与 `PhoneContextSync`：

1. **Step 1：修分类与修 ATS（止血层，最小独立提交）**
   - 更新 [project.yml](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/project.yml)、Mac/iPhone `Info.plist` 移除无效 CIDR 例外，用 XcodeGen 同步工程并通过 `verify-release-bundle.py` / `verify-mac-beta.py` 校验。
   - 重写 [AgentTransport.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/AgentTransport.swift) 错误分类（区分 `transientLink` / `configurationRejected` / `authenticationRequired` / `protocolIncompatible`，保留带底层 POSIX/Stream 错误的 `-1000` SOCKS5 瞬时判定），修复 [RelayCipher.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/RelayCipher.swift) 帧关闭误杀 SSE 的分类，修正 [DesktopModel.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Desktop/DesktopModel.swift) 自检错误映射。
   - **验证**：`MoMoAgentClientTests` 新增分类单测 + 跑通 `Tests/Support/test-tailnet-recovery.py`。

2. **Step 2：修 Tailnet 会话代次与 `PhoneRemoteAgent` 单一协调门控（连接层）**
   - 在 [EmbeddedTailnet.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/ClientUI/Network/EmbeddedTailnet.swift) 拆分 `nodeGeneration` 与 `sessionGeneration`，`suspendSessions()` 取消 `proxyCheck` 且不误触发 `needsRestart`。
   - 在 [PhoneRemoteAgent.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneRemoteAgent.swift) 去掉重复的 `NWPathMonitor`，统一 `sceneGeneration`、单飞探活与 401 复核，把 `AgentRTCTransport`、`LifeIllustrationStore`、`PhoneContextSync`、`PhoneNotifications`、`PhoneHealthSync`、`PhoneSourcesSync` 全部挂到协调器 `ready` 信号后触发，并为后台唤醒路径收紧超时预算（修复 `PhoneContextDelivery.expire` 顺序）。
   - **验证**：扩展 `test-tailnet-recovery.py` 与 `PhoneContextDeliveryTests.swift` 覆盖快速前后台切换与超时回收。

3. **Step 3：拆 `PhoneContextSync` 存储与读写通道（同步层 + 首次交付收口）**
   - 在 [PhoneContextSync.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift) 将记忆缓存拆至独立 `memories-cache.json`（带 `.completeFileProtectionUntilFirstUserAuthentication`），裁剪已送达 `Source` 的 `spans` 正文并按批合并写盘。
   - 彻底解耦 `refreshMemories()` 与 `uploadSources()`（包括修复 `prepareSubmission` 并发写与断网连续 500 次重试不 `break` 的问题），更新 [RemoteMemoryView.swift](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift) 绑定真实刷新与重试状态；补齐聊天游标 409 追平回归测试。
   - **验证**：在 `RemoteContextSyncTests.swift` 实测 500 条未上传录音 + 慢速/失败上传下记忆刷新耗时与主线程编码次数。

4. **Step 4：增量记忆 Manifest 与快照锁（第二阶段独立提交，对应修正后的 P3）**
   - 在 [momo_memory.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/momo_memory.py) 补齐读写一致锁与 `(mtime_ns, size) -> content_sha256` 缓存，在 [context_server.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Context/context_server.py) 暴露 `memory_manifest_v1`（挂入 `/context/v1/status`）与 `manifest`/`batch` 接口，**同步更新 [rtc_transport.py](file:///Users/syh/Workspace/MoMo-Agent-worktrees/connection-upgrade-plan/Apps/MacApp/Access/rtc_transport.py) `permitted_route` 白名单**，客户端实现协商与旧版全量自动回退。
   - **验证**：`test_momo_memory.py` + `test_webrtc.py` + `test_relay_access.py` + `RemoteContextSyncTests.swift`。

5. **Step 5：加密中继回退原型验证（第三阶段，仅在完成第二节 5 项前置条件验证后立项）**

---

当前模型：Gemini 4 Carbon (High)
