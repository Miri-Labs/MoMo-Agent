# 连接升级方案：第一轮 review 的采纳、驳回与复审要求

日期：2026-11-14。源码基线仍为 `4af63c1aaa7c047136a0527f531feae67379a209`。应用代码尚未修改。

用户要求先由 agy 的 Gemini 4 Carbon High 审查，核实采纳后实施；随后要求驳回后再复审一轮。本文件提交给同一 reviewer 复核，第二轮结束前不进入应用代码实施。

审查对象：[升级方案](../../plan/mac-phone-connection-upgrade-20261114.md)。第一轮完整结果：[review 原文](connection-upgrade-gemini-round1.md)。下述严重性以证据和可复现行为判定，不直接继承原文的 P0/P1 标签。

## 已核实并采纳的改进

1. **错误分类需要收窄，同时保留已验证的 SOCKS5 兼容行为。** `AgentTransport.swift:23–35` 确实把几乎所有 URL 错误当成网络故障；ATS、证书与明确配置拒绝不应触发通用重建。`EmbeddedTailnetTransport.swift:58–72`、`test-tailnet-recovery.py:443–455` 及 `ConversationSubscriptionTests.swift:203–218` 已明确依赖 `badURL` 冷恢复。首次改动不能只允许带 underlying error 的 `badURL`：既有 fixture 和实测入口并不保证它存在。应结合已验证端点/专用代理上下文保留有界兼容，并为带 POSIX/SOCKS underlying error 和 ATS 分别加回归测试。

2. **笔记读取与资料投递必须独立；网络失败应终止本轮上传。** `PhoneContextSync.swift:129–168,333–355,428–444` 的串行等待、上传失败继续遍历和共享 `inFlight` 均可直接核实。笔记 UI、前台恢复及重连只等待笔记任务；上传遇链路失败、429/可重试 5xx 时停止余下请求，交还有界重试调度，保留未确认条目。永久单条错误也不能持续占用后台预算，但必须保留可见错误及恢复入口，不能丢弃资料。

3. **需要减少共享文件的主线程全量编码与无关观察更新。** `PhoneContextSync.State` 同时保存全部来源载荷与笔记；`commit` 每次全量编码并重新赋值 `memories`。接受笔记缓存独立文件、原子迁移、相同文件保护等级，以及上传分页/回执批次的有限检查点。必须按 500 条积压测量实际行为，而不是仅以两个并发 Task 宣告完成。迁移不得删除唯一缓存或破坏旧版回滚读取。

4. **节点、会话和前台任务的代次必须区分。** 保留 `EmbeddedTailnet.generation` 对节点的现有含义；为池/proxyCheck 和手机恢复任务分别管理取消边界。`suspendSessions()` 当前未取消 `proxyCheck`；旧检查不能因取消而置 `needsRestart`。新的刷新不能把已取消旧任务当成有效工作，也不能由旧任务清理新任务的标记。接受按实际 OS 后台预算提前结束连接与读取，取消不能变成网络故障。

5. **协调范围要明确包括 RTC、插画与其他非紧急同步。** 接受统一恢复意图、身份与代次检查，合并重复的手动/路径恢复；插画、健康、资料与通知应按真实可达证据及并发预算启动。不能将所有业务恢复串在聊天历史完成之后；可见笔记仍需要独立恢复。两个路径监测器分属底层节点与手机业务生命周期，是否合并需满足所有通道，不能简单删除后漏掉 HTTPS/RTC 的路径事件。

6. **删掉凭据自动恢复的未经证实前提。** 方案第 92 行应明确现协议没有 refresh-token 接口。401 要按真实协议来源与配对状态处理；保留缓存和待确认操作。不得虚构“签名 401”或让未鉴权的 `/pair/identity` 证明设备未撤销。是否增加一次只读复核，需先明确它的身份绑定、请求预算和失败分类，不能把明确的鉴权失败放进无限重试。

7. **P3 路由、版本协商与测试宿主需写全。** 未来新增笔记接口时同步更新 `rtc_transport.py:permitted_route`，能力由 Context 自己的 `/v1/status` 自洽声明；覆盖私网、HTTPS、Relay 和 RTC 的接入校验。使用现有 Swift 包测试、Tailnet 编译探针、手机集成测试和 Python HTTP 测试；Relay fixture 未配置时的 skip 不能算实测通过。

8. **保留首轮可靠性与后续协议升级的阶段边界。** P0–P2 首先闭环；P3 单独实施验证；P5 中继分块及未来多通道故障切换需先满足配对、双通道在线、端到端身份与资源预算条件。首轮不自动迁移用户通道，也不把公网部署混入当前本地实施。

## 必须驳回或更正的判断

### R1：CIDR ATS 例外无效——错误，不采纳删除或全局放开 ATS

第一轮 P0-3 断言 `NSExceptionDomains` 不支持 CIDR，并建议删除 `100.64.0.0/10`。Apple 现行官方文档明确：从 iOS 17 / iPadOS 17 / macOS 14 起支持 IPv4、IPv6 及 CIDR 范围。当前项目最低系统版本处于支持范围。

- [Apple NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains.md)，Discussion 的 IP/range 规则。
- [Apple NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking.md)，系统版本差异与 CIDR 配置。

因此保留精确的 CGNAT 例外与代码端点限制，不新增 `NSAllowsArbitraryLoads`。现场 `-1022` 仍需要按真实安装包、实际目标 URL 和 OS 复现，不能从旧版 ATS 文档推导“手机 100% 失败”。方案第 93 行本就明确禁止全局放开 ATS，并没有所谓“选项 2”。

### R2：现有笔记 revision 是数量和最大时间戳——与源码相反

`momo_memory.py:780–795` 实际使用排序后的 `id + item.revision` 清单 SHA-256；单条 revision 来自正文 SHA-256。原文声称的 `(len(items), max(updated_at))` 不存在。方案第 128 行也明确要求哈希只比较相等。

接受捕获一致性的检查；拒绝用 `(mtime_ns,size)` 缓存作为正确性依据。相同大小且保留 mtime 的外部编辑不会被该缓存发现，第一轮建议并不能解决它自己提出的场景。方案第 144、154 行已经覆盖真实内容核验和外部文件修改。

### R3：方案把 badURL 一刀切列为永久错误——引用不存在

原方案第 86–100 行没有 `configurationRejected` 或 `.badURL` 枚举，没有要求去掉既有 SOCKS5 恢复。接受补充兼容说明，但不接受把尚未提出的错误实现认定为方案 P0。underlying error 只是一项证据，不能在没有回归验证时成为唯一允许条件。

### R4：PhoneContextDelivery 先 finish 后 task.cancel——顺序读反

`PhoneContextDelivery.swift:95–100` 实际是 `task?.cancel()` → `finish(...)` → `cancel()`。前一个 Task 取消已经先于 `finish`。仍可检查后一个取消回调与 `suspend()` 的顺序，但必须分别命名，给出真实触发条件，不能将其描述为“任务在清理前从未取消”。后台 OS grant 必须及时释放，不能为了等待不可控网络回调而超期占用。

同样，`checkProxyIfNeeded()` 创建独立 probe URLSession，`suspendSessions()` 的池失效不会直接取消这个 probe；存在生命周期未纳管风险，不等于第一轮描述的直接因果链已证实。

### R5：Relay 正常关闭必然 protocolFailure 且 SSE 永久死亡——未证实

`URLSessionWebSocketTask.receive()` 的返回消息类型是二进制或文本；正常关闭并不是返回一个 `.string` 关闭帧。真实关闭/超时错误应通过 fixture 验证。`RemoteTaskStore.swift:481–485,1133–1136` 还会在前台循环检查并重新创建已退出的订阅，第一轮漏掉了这一层，不能宣称只能手动切后台恢复。

保留对真实流中断的重连测试；禁止把密钥、身份、验签或解密失败一概降为普通瞬时错误，更不能因此放宽验证。`RelayTransport.swift:109` 并没有 8 MiB 累计响应上限；普通请求的这一限制在 `AgentClient.swift:112–118`，SSE 走独立流式路径。需要准确区分层次。

### R6：直接清空已回执 Source.spans——不具备安全前提

`PhoneContextSync.sources` 与 `prepareSubmission` 仍读取保留 envelope 的 span ID、generation、version；`stage()` 还可能直接返回已缓存 Source。清空 spans 会影响录音引用检查、来源重建与重新投递。若要精简载荷，必须先设计可靠元数据与 Archive 重建路径并测试，不能直接清空。首轮优先独立缓存、有限批次检查点和不触发无关 UI 更新；是否需要更深的来源持久层改造以积压测试证据决定。

### R7：方案已要求批量 manifest/batch API 和无条件自动中继回退——均非原文

方案只提出版本能力及分页快照，没有设计批量 ID POST 接口，也没有指定 `/v1/capabilities` 的挂载位置。补齐路由/Context 能力位置是合理建议，批量请求 50 ID 不应成为强制实现。

方案第 172 行已经说明每交换一条连接及是否多路复用需测量；第 186 行明确“支持多个预先授权通道后，才设计自动故障切换”。现有协议不支持双通道是后续前置条件，不是首轮必须重写配对的理由。

### R8：95% 根因占比、gzip 后大小和严重级别——无实测依据

未取得相应统计或真机复现，不能写“95% 来自……”或“100% 失败”。当前 `ContextService.Handler.respond()` 直接发送 JSON，第一轮没有给出该通道启用 gzip 的证据。保留结构性瓶颈与测试要求，不把估计当测量结果。游标保留窗口、快照分页和长期事件增长可后续验证，不以此为由改变现有永久幂等账本。

## 第一轮之后的基线验证

- `RemoteContextSyncTests`：9 项通过。
- `ConversationSubscriptionTests`、`ConversationDeliveryTests`、`RemoteTaskStoreTests`：合计 43 项通过。
- `Tests/Support/test-tailnet-recovery.py`：现有生命周期、代理、启动、取消和恢复探针全部通过。
- `Tests/AgentRuntime/test_momo_memory.py`：11 项通过（临时 uv 环境提供 aiohttp）。
- 本机安装包读取为 0.6.20 / 111；方案源码配置为 0.6.21 / 112。两者不混称为已部署修复。

上述是改动前基线，不能代替新增故障回归或真机验收。

## 第二轮 reviewer 的任务

请核实本文件各项证据，明确哪些第一轮结论撤回、修正或仍保留，以及剩余真正阻塞首轮实施的问题。重点检查修订后的最小 P0–P2 范围能否解决独立同步、取消代次和错误恢复，尤其是持久化与录音引用的安全边界。

请只读核对争议涉及的源码，不重新扩张到全仓库架构审计。没有证据的判断标为待验证。输出具体、简洁的第二轮结论和必须修改项；不要输出不存在于原方案的引用，不把未来 P3/P5 当成首轮已承诺实现。当前仍不修改应用代码。
