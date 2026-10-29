# Dream 机制核对与手机端记忆整理

核对日期：2026-10-18。实现已接入现有空闲队列，验证范围见文末。原先的日队列候选方案已撤回；用户提到按天，不构成强制按天处理的设计要求。

## 判断与来源

记忆整理需要可信证据、候选筛选、巩固和提交确认。日期可用于调度、输入展示、过期或交叉佐证。两套上游都没有把“收到某天结束标记”设为整理的必要条件。

本次以官方仓库的固定提交核对实现，网页用于导航：

- OpenClaw：`8afe5eff5d15d47c3f2453a84ecfb7a82e488653`。[Dreaming 概览](https://docs.openclaw.ai/concepts/dreaming)、[协调器](https://github.com/openclaw/openclaw/blob/8afe5eff5d15d47c3f2453a84ecfb7a82e488653/extensions/memory-core/src/dreaming.ts)、[阶段实现](https://github.com/openclaw/openclaw/blob/8afe5eff5d15d47c3f2453a84ecfb7a82e488653/extensions/memory-core/src/dreaming-phases.ts)。
- Hermes 核心：`22063fc099ec9ad8357d7f8f6e6248a0400680d3`。[核心后台 review](https://github.com/NousResearch/hermes-agent/blob/22063fc099ec9ad8357d7f8f6e6248a0400680d3/agent/background_review.py)、[本地空闲队列](https://github.com/NousResearch/hermes-agent/blob/22063fc099ec9ad8357d7f8f6e6248a0400680d3/agent/review_idle_queue.py)、[MemoryStore](https://github.com/NousResearch/hermes-agent/blob/22063fc099ec9ad8357d7f8f6e6248a0400680d3/tools/memory_tool_store.py)。
- Hermes Dream：以该核心提交中的[官方 catalog](https://github.com/NousResearch/hermes-agent/blob/22063fc099ec9ad8357d7f8f6e6248a0400680d3/plugin-catalog/hermes-dreaming.yaml)为入口。其 `tier: community`，版本 2.9.4，固定到作者仓库的 `63ac65e0155902f58822d9575b210c61ad6fc295`。[插件原件](https://github.com/itpartypattaya/hermes-dreaming/tree/63ac65e0155902f58822d9575b210c61ad6fc295)。官方介绍网页可能仍展示旧版本，以下判断统一采用 catalog 固定的源码版本。

阅读的上游原件保留在 `tmp_agent_output/20261018-dream-mechanisms/`。本轮仅阅读原件，没有执行上游脚本或安装插件。

## 上游实际机制

| 方面 | OpenClaw memory-core Dream | Hermes 核心 review | Hermes 社区 Dream 2.9.4 |
| --- | --- | --- | --- |
| 触发 | 维护一个默认凌晨 03:00 的可配置 cron，使用专用事件唤醒；普通 heartbeat 不反复整理 | turn 结束后的 nudge/review 机制，按触发范围决定是否可写 memory；本地模型可延后到空闲 | 安装独立 extraction / nightly job；先跑本地 precheck，有可处理事项才唤醒模型 |
| 证据 | 短期候选、真实交互召回、可信人类原文；排除 cron、工具、子 agent 等自我强化 | 对话快照；同模型复用完整缓存前缀，换模型使用摘要和近期原文 | 事实候选库与可信人类消息；抽取是独立工作，Dream 脚本本身不抽取事实 |
| 筛选 | Light 收集与去重，REM 提取局部模式和置信线索，Deep 评分与晋升 | review 模型判断持久知识、纠正与技能，不是一套 Light/REM/Deep 引擎 | Python 确定性阶段计算佐证、衰减、冲突和候选评分，不调用 LLM |
| 巩固 | 模型返回 added / merged / superseded 决策及旧条目锚点；宿主构造结果并检查来源和损失比例 | 经普通 memory 工具写有限 Markdown，精确 span patch 保留同条目其他事实 | 普通 memory 工具负责应用；一夜最多 6 个记忆变化、3 个新增，零变化有效 |
| 冲突与遗忘 | 合并需同一事实，替代需显式 lineage；人工 forget 有独立来源治理 | 后台破坏性 patch/remove 走 staged review，完整旧条目 pin 防止批准时改错对象 | 冲突不确定则询问；衰减是复核提示；不可逆 forget 需人的明确指令，并清理插件自身副本 |
| 资源 | 召回/证据数量和历史范围有界，模型调用在文件锁之外，落盘前重读 | 累计输入预算、模型路由、工具白名单、前台抢占取消、同会话本地排队合并 | 无事项则零 LLM，接近容量也可唤醒；脚本默认 600 秒是桌面预算 |

OpenClaw 的三阶段不等于三轮模型调用。Light 与 REM 的关键处理在本地执行，Dream Diary 是展示结果，不是长期记忆的事实输入。晋升评分使用相关性、频率、查询多样性、时效与巩固信号，且只有合格的实际交互查询能增加多样性。[评分实现](https://github.com/openclaw/openclaw/blob/8afe5eff5d15d47c3f2453a84ecfb7a82e488653/extensions/memory-core/src/short-term-promotion.ts)

OpenClaw 的 consolidation 使用精确旧条目和当前记忆版本；模型等待期间释放写锁，提交时重新核对来源和指纹，写入成功才标记晋升。其失败时 append-only 回退以已经通过筛选的候选为前提。[决策校验](https://github.com/openclaw/openclaw/blob/8afe5eff5d15d47c3f2453a84ecfb7a82e488653/extensions/memory-core/src/dreaming-consolidation.ts)、[提交实现](https://github.com/openclaw/openclaw/blob/8afe5eff5d15d47c3f2453a84ecfb7a82e488653/extensions/memory-core/src/short-term-promotion-apply.ts)

Hermes 本体已经有后台记忆工作，不能因 Dream 属于社区插件而忽略本体。自动 review 受 enabled、nudge、模型路由及累计输入预算约束。前台新输入取消当前 review；本地模型队列按会话合并，退出前仍排队的 review 不持久化。核心 memory 工具自身有容量、批次原子性和条目锚点保护，当前文档还规定后台 patch/remove 要审阅。MoMoAgent 沿用自己的证据及提交规则，没有照搬其后台写权限。[官方核心说明](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory)

社区 Dream 的本地 precheck 只因 actionable 候选、冲突、衰减、警报或容量压力唤醒。临时事件和主题本身不打开模型门禁。这个版本默认容量预警为 85%，与 Hermes 核心文档建议的 80% 不同。其 extraction 游标以 `(timestamp,id)` 处理相同时刻消息，但完成 ACK 根据匹配的 cron assistant 回复判断，连续无回复后还能警告并推进；本应用采用实际原子提交确认，不采用这类跳过语义。[precheck](https://github.com/itpartypattaya/hermes-dreaming/blob/63ac65e0155902f58822d9575b210c61ad6fc295/skills/dreaming/scripts/dream-precheck.py)、[extraction](https://github.com/itpartypattaya/hermes-dreaming/blob/63ac65e0155902f58822d9575b210c61ad6fc295/skills/dreaming/scripts/dream-extract-precheck.py)

## MoMoAgent 原来已有的能力

已有 `AutomaticInsights` 空闲/系统后台入口、可配置模型与推理、真实 memory 工具、有限分类 Markdown、批次最终容量校验，以及重放日志支持的文档与状态原子提交。已有证据逐字校验、来源可访问性检查、配置/记忆 generation fencing、用户删除/纠正/遗忘屏障、聊天抢占取消和 120 秒模型 deadline。已有承诺完成/取消规则：必须有明确新聊天证据，不能因为日期经过关闭。录音说话人未认证，只能形成事件。近期事件的 30 天活跃记忆期限也已存在。

这些能力已经接近 Hermes 的后台 review 与受限 memory 工具部分。此次复用该入口，没有新增第二套 review 或原文库。

## 本次实现

1. **持久候选池。** 从原有 Pi 用户输入和档案转录选取资料，排除助手、工具、上下文替换和本地敏感内容。移除只取近期少数会话、末尾消息和近期录音的隐式遗漏。Pi 仍只解码完整 record 不超过 65,536 字节的行，过大或含大附件的记录整行跳过；转录/聊天原文也有 65,536 字节筛选上限。因此候选池覆盖这些边界内的合格原话。日期只用于来源解释、遗忘屏障及跨日佐证，无日队列、日完成门禁或录制结束依赖。
2. **实际输入预算。** 每批最多 24 个新来源。长原话按最多 1,024 UTF-8 字节分段，保留顺序和原引用。按实际 WireJSON 编码字节数控制请求，预留输出及系统/工具空间。已有记忆只装入完整条目，未装入的条目留在文件中且不可被本批编辑。
3. **精确进度。** 完成检查点为持久 `sourceID → hash`，与记忆提交一起写入。同一时间戳、迟到旧消息和修订后的正文分别处理。索引不裁成最近 N 条；仅完整扫描成功后收缩确实消失的来源。辅助旧聊天不推进其他来源的检查点。
4. **本地 preflight。** 来源目录成员、Pi DB/WAL 的大小/高精度修改时间/inode、档案 revision、记忆内容和遗忘屏障构成扫描指纹。输入不变且没有到期工作时跳过原文扫描和模型。扫描至少间隔 60 秒，新变化在冷却中保留下一次唤醒时间。目录增删、转录修改/删除、用户编辑和到期重试仍能进入检查。
5. **手机资源。** 每次唤醒仅 1 个来源批次。模型保留最多 120 秒共享截止点，校验失败最多补 1 次工具回执修正，不按阶段另起模型。SQLite 原文读取和候选排序/编码在 utility task 执行，读取结束即关闭语句和数据库。模型调用时只持有普通数据。开始聊天、关闭、配置改变或系统后台过期取消时，未提交来源保留待处理。
6. **隔离重试。** 每个失败来源哈希退避一小时，其他就绪来源可继续。取消或崩溃后的 admission 保留一分钟边界。完整扫描失败保留原检查点并退避；被删除来源的旧失败移除后不持续唤醒。修改配置使旧结果失效，释放旧来源退避。
7. **受限巩固。** 复用已有精确 patch，把新聊天明确纠正的一个旧事实片段更新，并保留同条目其余内容、旧新来源及 `supersedesHash`。完整快照 revision、唯一匹配、来源时间与 kind 均校验；较早迟到证据不能替代较新事实。跨日已核对聊天可提供有限辅助证据，录音不能据此修改用户资料或完成承诺。
8. **调度闭环。** 来源积压、失败和冷却唤醒纳入已有 `AutomaticInsights`。关闭或处理完成后，不因记忆队列每分钟重复唤醒。iOS 决定实际后台执行时机。

## 当前能力边界

本轮的本地门禁检查新证据、已变化的旧记忆及容量压力；语义冲突与是否值得长期保存仍由受限模型判断。没有引入上游的召回评分、独立事实库、三阶段调度、Dream Diary 或自动任意合并多条记忆。容量维护目前可以原文归类、避免重复和有新证据时修正；无新证据时不自由删写事实来腾空间。

“明确纠正旧偏好”与“从行为推断稳定偏好”含义不同。当前后台协议继续要求偏好有两个不同日期的原话，因此单次偏好纠正不会自动覆盖旧值，原始证据仍可供之后核对；用户直接编辑的版本优先。后续若增加单次纠正通路，需要独立的显式确认协议，不能仅靠关键词或较新时间判定。逐字引文校验可证明来源存在，不能单独证明模型理解和概括正确。

## 验证

最终回归：56 项，55 项执行通过，1 项真实外部模型用例未启用。日志为 `tmp_agent_output/20261018-dream-mechanisms/tests-final-verified.log`。命令：

```sh
swift test --package-path Packages/MoMoAgentKit \
  --scratch-path tmp_agent_output/20261018-paired-sync/SwiftPMFinal \
  --filter 'MemoryDream|AutomaticInsightsTests'
```

覆盖同时间戳积压、逐批重启、迟到/修订资料、5,000 条检查点不裁剪、来源删除、同日失败隔离、真实编码预算、Unicode 分段、跨日辅助证据、目录/WAL/档案/记忆指纹，以及 105 条消息分 5 次唤醒。新事实 patch 覆盖片段保全、来源链、用户编辑、录音拒绝、较早迟到证据与较新辅助证据组合拒绝、偏好同日拒绝与跨日成功。已有工具回执修正、容量回滚、关闭及迟到结果拦截、重放恢复与事件过期用例继续通过。

本地测试使用真实 Pi/SQLite、档案和持久化实现，并使用受控模型响应检验失败及迟到提交。真实外部模型用例为显式启用。本轮尚未验证手机后台到达率、耗电、真实模型内容质量及真机长历史扫描耗时。

2026-10-19 安装 `1.7.4` 后，手机解锁启动。真机状态确认检查点格式已迁移为 1，自动整理使用手机原有的已保存模型配置，`lastCompletedAt` 首次出现有效完成记录；00:19 完成的最近一批 `changedEntries=1`，容量错误已清除，无来源重试。累计完成 96 个来源检查点，687 个来源仍待分批处理，持久来源中有 5 条事件记忆。这证明真机的模型整理与原子提交链路已实际执行；尚未逐条人工核对这 5 条事件的概括质量。此时处于前台，不能据此推断 iOS 后台到达率或耗电。私有状态快照在 `tmp_agent_output/20261018-sync-release/phone-dream-1.7.4-first.json`，不提交内容。
