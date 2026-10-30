# Omi 设计研究与 MoMo Agent 的取舍

研究日期：2026-10-17。对照 MoMo Agent 基线 `7d4f4a1`。Omi 固定在 [`00e09210c77f9abfa34c841569dc0bf178deee0f`](https://github.com/BasedHardware/omi/tree/00e09210c77f9abfa34c841569dc0bf178deee0f)，不把后续 main 的变化混入结论。只学习设计，本轮不引入 Omi 代码或依赖。

## 结论与阅读边界

最值得学习的是：原始上下文可靠保管、派生工作可恢复、观察与长期记忆分开、检索结果回查当前权威数据、用户反馈改变后续行为，以及主动帮助有预算和可核验结果。这些与 Personal Agent 定位有关，不能只看录音如何分块。

Omi 不是一套可以整体移植的架构。仓库同时存在移动端、云端后端、Omi Desktop，以及独立的 Context for Claude。后者明确不共享 Omi Desktop 的进程、数据或实现；不能将它的本地 SQLite 设计描述成 Omi 全产品的存储方式。`backend/utils/memory_ingestion/ARCHITECTURE.md` 明确该目录是评测入口，产品提取另在 `utils/llm` 和 `utils/memory`。`agent_capabilities` 的共享编辑能力也明确尚不等于已经挂载到聊天。以下区分已追踪的调用入口、可复现的纯函数行为与仍需产品验证的效果。

## 1. 原始上下文与处理结果分别确认

Omi 移动端先把音频放入本地 WAL。上传被接受不等于转录成功；异步 job 要经过后续对账，只有终态 `completed` 才能确认本地 WAL 已同步。部分失败保留重试；整个任务被证明输入无效才进入永久失败分类，不能因为一个坏文件放弃正常的同批文件。

参考：[恢复记录](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/docs/offline-sync-stall-recovery.md)、[终态策略](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/lib/services/wals/sync_job_policy.dart)。

MoMo Agent 已有 InboxCustodian、持久接收回执、Archive 原音和派生转录，不能再加第二个 WAL。应保留现有确认边界：手表是否送达、手机是否持久接收、已接收范围是否分析/识别完成分别判断。转录失败不倒退接收状态，也不允许为了清空进度删除原音。增量分析每一页只确认实际覆盖范围，未分析尾部必须仍可恢复。

## 2. 恢复只有一个执行所有者，唤醒可以有很多来源

Omi 的 `RecordingTransferCoordinator` 汇集启动、前台、联网、设备连接、socket 重连、停滞、冷却结束和手动重试；事件触发同一个执行入口，而不是各启动一条同步循环。并发唤醒合并，后台有界推进，失败退避。`SyncReconciler` 在失败后也重新安排检查，防止一次异常永久停摆。上传入口还有账户共用的串行 gate 和 Retry-After，防止几个业务入口互相绕开冷却。

参考：[执行所有者](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/lib/services/wals/recording_transfer_coordinator.dart)、[对账](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/lib/services/wals/sync_reconciler.dart)、[上传 gate](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/lib/services/wals/sync_upload_gate.dart)。

MoMo Agent 的 PhoneReceiveCoordinator、TranscriptionCoordinator、AutomaticInsights 各有所属状态，不能机械合为一个超级调度器。借鉴的是每类状态只有一个所有者：平台后台任务提供执行时间，协调器领取工作，Archive 决定 durable 状态。前台/后台/新数据/重试只唤醒协调器。后续需要检查和展示“为什么等待”，而不是每个入口各加重试计时器。

## 3. 活跃新数据优先，但 Omi 的具体队列并非严格实时优先

Omi 将 fresh 与 backfill 分类，混合新旧输入保守归入 backfill；时间信任也单独记录。默认 fresh 年龄阈值为六小时，并不等于本地日历的“今天”。云端 backfill 有每账户所有权、执行 epoch、lease、补偿扫描和确定性投递名。运行手册明确：可领取任务之间的延迟偏好不能重排已执行或已投递的 Cloud Tasks；部分新排序与 sequencer 还受部署开关控制，不能声称线上已全部开启。

参考：[分类代码](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/sync/lanes.py)、[运行手册](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/docs/runbooks/sync-two-lane.md)。

MoMo Agent 保留已经实现的当日、近 30 分钟、历史闲时和同级轮转。这里该学的是有界领取、执行代次、可恢复状态及最老等待时长观测，不能复制 Firestore/Redis/Cloud Tasks，也不改为六小时阈值。分析和识别是两个资源阶段；产品上仍是一件“整理录音”的工作。预取不能越过统一优先级，分析尚未发布窗口时也不能让历史任务趁空先跑。

## 4. 判断停滞依据真实数据进展

Omi ring 传输分别限制初始响应、数据停滞和整体时限。重复 BEGIN、ACK、INFO 和空 DATA 不算进展；有效 DONE 到达可以停止无线侧停滞计时，但仍需完成本地持久保管验证。超时后停止新数据接纳，排空已经接纳的数据，保留待恢复 WAL，不能伪造完成或推进已保管边界。

参考：[实现和限制](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/docs/offline-sync-stall-recovery.md)、[ring 传输](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/app/lib/services/wals/ring_storage_sync.dart)。

我们应按接收字节/源帧覆盖/已提交窗口判断进展，不因重复状态报告重置新鲜度。现有 PhoneReceiveCoordinator 已拒绝重复 revision 刷新新鲜度。WatchConnectivity 没有 Omi BLE 的同一控制面，不移植其 5/15 秒或 30 分钟常数；iOS 收回后台时间也不等于任务死锁。

## 5. 原始记录、观察、长期记忆和待办是不同数据

Omi memory domain 将 Conversation 放在记忆上游；新提取先是 Short-term，长期事实通过绑定当前版本和证据的 admission 才可写入。任务和目标属于 workflow，不是记忆层。当前运行链路还有 daily sweep、确定性 required intake、过期处置与旧格式兼容；不能把图中的“consolidation”误解为每条音频都运行一个通用整理 Agent。

参考：[领域模型](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/docs/memory/domain_model.md)、[当前记忆入口和维护链路](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/memory/ARCHITECTURE.md)、[事务所有者](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/database/memory_apply_store.py)。

这是 MoMo Agent 下一阶段最大的可学之处。目前 MemoryTools 只在用户要求时管理 USER/MEMORY 紧凑文本，AutomaticInsights 主要生成时间线总结和首页建议，尚不是具有来源、有效期、冲突、反馈的生活记忆系统。

建议后续最小演进：原始来源保留 → 有来源的观察候选 → 核实主体、时效和冲突 → 可更新的长期事实；事项另保留承诺人、期限、状态、依据和执行回执。显式“记住这个”仍可走直接用户意图，不必照搬所有写入都先排云端 ST 的流程。不恢复已取消的独立计划页，也不在本次性能优化里顺带接入日程、邮件或自动建待办。

## 6. 记住“谁说的、说的是谁、何时有效”，并让纠正改变后续行为

Omi 不把转录的默认 speaker 0 当成用户身份。owner attribution 使用带 scope 的说话人 cluster；同一个数字跨 scope 不代表同一个人。没有唯一 owner 证据时不允许将话归成用户事实。daily sweep 还区分 proposed、observed、decided，拒绝把未决定的建议写成已承诺的长期属性。用户否定的记忆会作为有界反馈进入后续提取；useful 不会顺手解除用户先前的 suppress。

参考：[主体归属](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/conversations/owner_attribution.py)、[每日整理](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/memory/daily_memory_sweep.py)、[纠正反馈](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/memory/rejected_memory_feedback.py)、[使用偏好](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/memory/memory_use.py)。

MoMo Agent 当前无可靠声纹归属，不能从全天环境录音自动推断“我喜欢……”就是用户偏好。未来候选至少记录 subject（含 unknown）、observedAt、validFrom/To、assertionKind、confidence、source/version 与 supersedes；用户明确纠正优先于重复出现的旧提取。字段应随着实际用例落地，不提前搭完整知识图谱。

## 7. 检索先找候选，再回查当前事实；中文方案要单独验证

Omi canonical vector search 对候选做有界 overfetch，再从 memory_items 回查权限、状态、来源代次和 projection commit。向量库是可重建索引，不能以旧向量中仍有文本为由返回已删除记忆。检索还必须带结果预算、完整性与继续读取信息。

参考：[向量搜索](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/memory/vector_search_service.py)、[检索边界](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/retrieval/ARCHITECTURE.md)、[混合重排](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/retrieval/hybrid.py)。

不能直接搬 hybrid.py：它的 tokenizer 是 `[a-z0-9]+`，纯中文查询没有 BM25 信号；它只在向量候选内重排，未召回的专名不能凭 RRF 找回来。MoMo Agent 现有 searchTranscriptsPage 用 literal substring，结果回查原文，适合精确词但没有语义召回，日期仍按 session 起点过滤。

后续应先做按 passage 实际发生时间过滤，测试跨午夜/长录音；再评估独立的中文词法召回与语义召回，合并候选后按稳定 source ID 去重、回查 Archive，并返回原句和上下文。不要用摘要索引替代全文，也不要把未搜到解释为未发生。

## 8. 引用要保留限定条件，录音纠错采用覆盖层

Omi 的 memory evidence renderer 以完整 claim 为单位装入预算；装不下就明确省略并提供分页，不把句子后半段的例外截掉后当完整证据。转录纠正则保留 captured text，使用带锚点/版本检查的 overlay 投影，返回 original_text，撤销走 journal，而非让整理 Agent 原地改掉原话。

参考：[完整证据装箱](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/retrieval/memory_evidence.py)、[原文与纠正投影](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/agent_capabilities/transcripts.py)。

我们已有 SourceReference、版本校验、原音回听和可继续读取的 TranscriptPage。ContextBuilder 的短摘录必须继续标明 truncated；未来长期事实读取应保全整条 claim，避免“喜欢茶，但出差时不喝”只留下前半句。未来纠错先实现用户主动修订与依据，再考虑自动纠错，不把现有 ASR 原文静默改成更流畅的改写。

## 9. 原始状态与索引更新采用可恢复提交

Omi 在同一 canonical 事务提交 item、operation journal 和 projection/vector outbox。异步 worker 先重新读取当前 item，再执行幂等外部写入；严格成功才 acknowledge。删除先使权威记录不可见，迟到任务受 account/source generation 与 tombstone 限制，索引清理可以重试但不能让数据重新出现。

参考：[apply store](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/database/memory_apply_store.py)、[outbox worker](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/database/memory_outbox_worker.py)。

MoMo Agent 已有 Archive 事务、generation、attempt ID、文档修复及 Agent 来源失效，不要重复引入通用消息队列。本轮增量发布沿用这些保护。未来 embedding/跨来源记忆建立独立派生索引时，再在同一 SQLite 事务登记 outbox；不能在主记录提交后靠一次 best-effort 回调保证索引必达。

## 10. 主动帮助以结果和打扰成本衡量，执行权限由应用持有

Omi proactivity v2 有明确 producer、source revision、去重、claim、费用预算、结果 outcome 与 push 资格。生成内容和投递分别管理；“有建议”不自动获得推送资格。共享 agent capabilities 把 user 与 dream 权限由调用方传入，模型不能通过参数自授权限；自动编辑需要独立核验、当前快照和撤销记录。Dream verifier 不读取提议者的推理或另一核验者的回答，避免同一个错误相互证明。

参考：[proactivity 入口](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/proactivity.py)、[producer/预算](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/config/proactivity_v2.py)、[结果记录](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/database/proactivity.py)、[执行权限](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/agent_capabilities/effects.py)、[独立核验](https://github.com/BasedHardware/omi/blob/00e09210c77f9abfa34c841569dc0bf178deee0f/backend/utils/dream_verify.py)。

我们已有 SystemActionCoordinator 的连接授权、操作身份和回执，首页建议有来源校验与 dismiss 缓存；缺口是建议是否有用、是否已经处理、是否重复打扰的闭环。后续先补可见建议的 acted/dismissed/expired 结果与语义去重，再讨论通知和主动执行。无需复制 Omi 的收费档位或默认两次强模型核验；按风险和已有授权决定。录音内容不能替代用户当前的行动授权。

## 本轮与后续顺序

| 顺序 | 工作 | 收益与验收 |
| --- | --- | --- |
| 本轮 | 增量分析交付、有界 PCM 复用、统一优先级与取消恢复 | 首窗口能提前交给 ASR；重复转换帧减少；中途取消后已提交覆盖保留；当日不被预取历史越过 |
| 下一轮候选 | passage 时间检索、中文召回评测集 | 昨晚/今天/跨午夜查询按真实发生时间；专名、同义表达、否定和例外均可测 |
| 下一轮候选 | 有来源的观察与记忆生命周期 | 不把旁人话写成用户偏好；用户纠正影响后续读取与提取；来源删除立即失效 |
| 后续候选 | 事项与建议结果闭环 | 同一承诺不重复建议；已处理/无用可反馈；执行有真实回执 |
| 有实际索引需求时 | 派生索引 outbox 与修复 | 进程在任一提交点退出都不会丢更新或恢复已删除数据 |

除本轮音频实现外，其余为设计研究建议，未声称已经实现，也不自动扩大来源接入或外部行动权限。

## 验证范围

已阅读固定版本的入口、实现与相关测试，额外对直接加载的 Omi 纯函数做了 10 项隔离行为检查，全部通过：中文分词无信号、英文 BM25 有信号、RRF 不能恢复候选外结果、整条 claim 保留例外、预算内完整输出、过大 claim 整条省略并继续分页、未知说话人不归属用户、跨 scope 同号分开、合成默认 speaker 不构成身份依据。报告保存在本地研究目录 `omi-behavior-checks.json`。这些检查验证代码行为，不是 Omi 云端服务、实机效果、检索质量或完整测试套件的验证；也没有运行 Omi 生产任务。
