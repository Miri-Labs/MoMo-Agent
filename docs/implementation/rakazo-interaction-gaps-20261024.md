# Rakazo 交互缺项：实施合同

日期：2026-10-24。研究交接稿；已依此实施，结果见 `rakazo-interaction-implementation-20261024.md`。MoMo 基线 `e63f10899430aa3f9129bfc060994b48a40e64cc`，分支 `codex/hermes-app-20261021`。Rakazo 固定源码 `1e92d28aab97c22e396348a64b2fc2a1e47c9c68`，本地 `research/rakazo-20261024`。本轮不重复实现共享聊天、完成唤醒或 APNs。

## 1. 必须保留的原生边界

Rakazo 的等待是真正暂停一次 attempt：`pauseRunForInput` 将 run 写为 `waiting_input`，清除 lease，结束 attempt，再持久化提问和事件；`QUEUE_HOLDING_RUN_STATUSES` 排除 `waiting_input`。普通新消息因此可以创建另一个 run。电脑接管则有独立的 `waiting_takeover`，归还通过精确 `controlRunId` 将原 run 重新入队。

Hermes 当前机制不同：

- `tools/approval_gateway_wait.py:_await_gateway_decision/_poll_event` 在工具线程内等待 `threading.Event`；取消返回拒绝，绝不能当作批准。
- `tools/clarify_gateway.py:wait_for_response` 同样阻塞，并按精确 clarify ID 完成；`attempt_text_response_for_session` 能把普通文字当答案，产品的新消息不能误入这个路径。
- `gateway/session_authority.py:_drain` 在 `await _execute_claimed(...)` 返回后才 settle 并领取下一条。`LiveSession.controls` 只是这个仍在执行的 claim 的控制投影。
- `Apps/MacApp/Runtime/personal_agent.py:admit_input` 当前把所有输入送进同一个 root，所以“等待”占住了整段聊天。仅设置 `independent_chat_while_waiting=true`、删 pending control、取消等待 Future，都不能解决这个问题。

**本轮实现：一条可见 conversation，多个受信 work，每个 work 使用 Hermes 原生执行会话。** A 等待时保留 A 的原 claim 和审批 Future；普通新消息 B 使用自己的原生会话。FIFO、generation、批准、停止、压缩、未知结果恢复仍全部由 Hermes 管理，不新建 LLM 循环或计划系统。

## 2. 可见 conversation 与 work

`conversation_id`、公开 `session_id=momo-main-<assistant_id>`、messages 的全局 seq 保持不变。普通发送默认是独立新 work；点具体任务“补充”才发送 steer。首次 work 可保留已有 root，后续新 work 的 native root 为服务端派生的 `momo-work-<operation_uuid>`，客户端不能任意指定 session。

在现有 `ProductStore` 增量添加 work 路由，不迁移旧输入、不重放旧消息：

- `works(id, native_root UNIQUE, origin_run_id, title, created_at, context_through_seq, context_json, cancel_requested, cancel_operation_id)`。
- inputs 增加 `intent`、`work_id`、`delivery_state`；旧记录按原 root work 解释，旧 pending 行保留原 run_id、owner_scope、target 和请求正文。
- work 不是第二个执行状态机：运行/等待/最终结果从 Hermes admission、controls、process/delegation ledger 投影。只保存产品路由、上下文快照、用户取消意图和幂等回执。
- `PersonalAgent.owns` 必须以受信 work 表 + `authority.logical_owner` 压缩别名验证；不能仅检查 `momo-` 前缀。project/runs/completions/notifications 均覆盖这些 roots。

### 上下文继承

新 work 第一次 admission 前，在接受事务中固定 `context_through_seq`，保存已可见的 user/assistant 消息快照。通过原生 `conversation_history` 的对应角色提供，保留原 user 正文；不得拼进 system，也不得复制其他会话的 tool-call/approval 内部消息。建议最近 40 条且最多 24 KiB，写明被省略范围，可继续使用原生 session_search；同一 operation 重试始终使用原快照。

另提供一段服务端生成的简短任务状态，例如“任务 A 等待用户批准，尚未执行”，只包含 IDs、标题和可信状态；不得将 A 未批准动作或其他 work 的用户正文转换成 B 的授权。每个 work 使用同一个 Hermes profile 和原生记忆；第一次之后按自己的原生 history 续跑。

### 旧客户端兼容

旧 `{operation_id,content}` 仍是合法 new；旧显式 `{target_run_id,execution_generation}` 仍按 steer 处理。返回 receipt.session_id 保持公共 root。

`/v1/runs/{id}` 也被旧手机直接读取，不能只在 `/conversation/runs` 改投影。给 `api_server_authority_runs.run_projection` 加可选产品投影 hook：仅对本产品已登记的 work run，将公开 session_id 映射为公共 root，并附加 execution_session_id；**run_admission、respond_run、stop_run 的真实 session 不变**。这样旧 journal 的 session 验证继续有效。新 Swift 把执行 session 作为诊断/关联字段，不能用它替换 schema1 的 task.sessionID。旧日志、草稿、未回执请求、legacy 消费回执全部保留。

## 3. 消息与任务控制 API

继续现有路由；字段兼容性是加法，不引入单独计划页。

### POST `/momo/v1/conversation/messages`

new：`{operation_id, content, intent:"new"}`，intent 缺省且无 target 也等同 new。

steer：`{operation_id, content, intent:"steer", work_id, target_run_id, execution_generation}`。work_id 可由旧请求 target 安全推导；禁止 target 与 work 不一致。

成功回执保留已有字段并增加 `work_id`、`intent`、`delivery_state`。new 的 disposition 为 queued；steer 为 steering，真正被 agent 消费后才标 applied。不得声称“立即生效”。

409 错误码：`stale_target`、`waiting_for_input`、`steer_unavailable`。UI 保留原文字和目标，提供“作为新消息发送”，不能悄悄重新 POST new。普通 new 永远不能应答 approval/clarify。

审批、澄清继续使用既有 `/v1/runs/{id}/approval|clarify`，body 仍是精确 `request_id + execution_generation + choice|answer`。等待卡可取消；新消息不清除等待卡。

### 严格 steer 的原生约束

现有 `steer_queued` 是可靠 ticket 转移，但拒绝或未消费时会退回 FIFO；MoMo 的 catch 又静默放行。必须一起修：

1. 接受 steer 前验证目标仍 started、generation 相同、无 pending controls、已有能消费 steer 的 adopted agent；失败不创建新 work。
2. 原生 admission 标记该输入为产品的 **steer-only**，产品记录中的 target+generation 是受信校验依据。原生 claim 检查不得把它当独立 turn 领取；拒绝/退回 queued 后也不得执行。这条约束必须跨恢复，不能只靠取消的时间窗口。
3. 复用 `steer_queued` 和原生 ticket/withdraw 机制。转移未被消费时，投影 `not_applied`，并安全终结该 queued 输入；保留正文与回执，允许用户显式另发 new。不能因 409 重试而复制 user 消息。
4. 最小 seam：原生 `check_api_turn`/claim 校验调用产品 `validate_input_delivery`，配合 `session_queued_controls` 的 transfer settle/revert 通知产品；只接纳本产品已登记的精确 request ID。generic Hermes 的 FIFO 语义保持原样。

### POST `/momo/v1/conversation/work/{id}/cancel`

body：`{operation_id, execution_generation}`。id 是下文 work/background row 的完整 ID；generation 必须对应该 row 的 incarnation，不能只按标题、PID 或前缀匹配。

返回 `id, cancel_requested, state`；202 表示已请求停止，200 表示已有最终结果。先持久化取消意图和幂等回执，再调用原生 stop/interrupt/kill。重复同 operation 返回同一语义；过时代际返回409。不得“收到 HTTP200 就显示已取消”。

根 work 取消：拒绝其新补充/完成自动续跑，停止精确当前 run、取消尚未执行输入，停止该 work 所属后台子项；B 与其他 work 不受影响。单独子项取消只停止该子项，原 work 仍可得到一次带真实取消结果的完成报告。完成与取消竞争时以原生真实最终状态为准；已完成不能改写成 cancelled。

## 4. Swift / UI 稳定字段

扩展现有 `RunSnapshot`（实际定义沿用当前源文件）、`ConversationWork`、`RemoteTaskStore`，不另造 store。`/conversation/runs.data[]` 和 `/v1/runs/{id}` 增加：

`work_id, title, origin_run_id, execution_session_id, cancellable, cancel_requested, wait_reason`。

`wait_reason` 可为 `approval | clarify | computer | null`；原 status/pending_controls 保持可解码。clarify 不再被误看成普通 running；waiting 仍是非终态。

`background_work[]` 使用以下统一合同（根 work 仍在 runs，避免重复卡片）：

| 字段 | 含义 |
| --- | --- |
| id | `process:<native_id>` / `delegation:<native_id>`，完整、稳定、可用在 cancel 路由 |
| kind | `process` / `delegation` |
| work_id | 归属 work |
| origin_run_id | 发起它的可见 run |
| title | 原始任务短标题或 command 摘要，不能只是“后台任务” |
| execution_generation | 服务端登记的子项 incarnation 整数，不是 PID，也不能用当前无关 run 的 generation |
| state | queued/running/stopping/completed/failed/cancelled/unknown，真实原生状态映射 |
| native_state | 可选原生细分状态，如 stalling、interrupted、kill_failed |
| report_state | 原有完成回执汇报状态，保留 |
| cancellable | 当前是否可请求取消 |
| cancel_requested | 用户已请求但尚未证明终态 |
| summary | 可选简短结果；无私密长输出 |

后端保留终态行，至少到产生可见结果且已读，不能点击取消后行直接消失。也可写入去重 system 消息“已停止 ××”，不能伪装为 Hermes 自己生成的文本；同一取消只能一次。

UI 继续共用 `RemoteTaskControlsView`：任务标题 + 状态 + 精确补充/取消；取消请求放按钮内 loading/禁重；等待卡能继续回答、也能取消；任务区域限高可滚动，composer 始终可用。`steeringTarget` 增加 workID；普通输入默认 new，只有点任务补充才定向，退出补充恢复普通输入。

## 5. 后台 process / delegation 原生接点

### Process

复用 `tools/process_registry.py`。`ProcessSession` 已有 `parent_session_id/owner_task_id/started_at`；列表用无消费副作用的 `list_sessions` 或增加受限 snapshot helper，按精确 parent_session_id→work 路由。`poll/read_log` 会标记已消费，不用于 UI 定时列表，否则会吞掉 Hermes 主动完成汇报。

取消只调 `kill_process(exact_id, source="momo.work.cancel", consume_output=False)`，保持完成链能报告真实取消；整 work 已取消则由现有 completion source gate 阻止自动复活。先验证 exact ID、归属和登记 incarnation，不能直接使用 `registry.get` 的前缀匹配作为授权。原生已做存活后代核验；返回 `process_running` 或 kill 错误时继续显示 stopping/失败可重试，不伪造 cancelled。

### Delegation

复用 durable `async_delegations` ledger，结合 `list_async_delegations()` 的 live snapshot。当前只有 `interrupt_all/interrupt_for_session`，缺精确 child ID 入口：增加小 helper `interrupt_delegation(id, expected_parent, expected_incarnation)`，在 `_records_lock` 下校验，锁外调用既有 interrupt_fn。仍由正常 finalize 产生 interrupted 完成事件，不直接写 completed/cancelled。

整 work 取消先 `refuse_for_session` 建立 dispatch fence，再 `interrupt_for_session`；避免“先扫子任务，随后又派生一个”的竞态。不能使用 interrupt_all。进程/委派从其他 CLI、transcript session 或不属于本产品的记录不得暴露或取消。恢复后只有 durable receipt 的条目仍可查看；不能找到可靠活体句柄时标 unknown，不假装已停止。

## 6. 电脑接管：保留驱动，补真实等待

已有 `Access/desktop_control.py` 的 flock + epoch、`DesktopControlHost.swift` 的 agent/human admission、输入前再次检查与 event_id 去重是正确基础，不重写 driver。当前 MCP 只是把“用户正在控制”抛给 LLM，没有等待、没有原任务归还绑定。

### 最小原生 seam

在 `gateway/session_api_turn.py:wire_api_observers(agent, owner, ...)` 已知精确 `(authority, session_id, generation)` 的位置，给本产品 agent 绑定一个受信 computer gate。`agent/tool_executor.py:_dispatch_authorized_once` 在现有 scope/guardrails 检查后、实际 execute 前调用该 gate，仅匹配本产品两项 computer MCP tool 的真实注册名。gate 异常必须 fail-closed；不要使用当前失败会继续 next_call 的通用 plugin middleware 来承担互斥安全边界。

gate 在原生工具线程内等待，保留原 claim，使用现有 interrupt/human-wait heartbeat 模式，可被该 run stop 唤醒。**等待发生在 MCP RPC 之前**：`mcp_tool_handlers` 的 `server._rpc_lock` 是全局串行锁，不能在持有它后无限等待人，否则 B 的其他 MCP 调用也会阻塞。不能从共享 MCP 子进程的环境变量猜 session；那里并不是每调用独立环境。

持久化 waiting 关联最少 `work_id/run_id/generation/tool_call_id/lease_epoch/state`，由产品现有 store 线程安全入口写入（不能在工具线程直接使用主线程 sqlite connection）。用于 UI、去重、取消与重启判断，不能拿这张表代替原生 claim。

### 互斥与归还

- 在同一 lease 文件内增加当前 agent work 归属和待恢复 work，不再另设第二套 computer lease。多 work 不能交错操作同一桌面；非拥有者等待，运行结束/取消才释放该 work 的计算机占用。普通聊天不需要此占用。
- 人工 acquire 原子记录被暂停 work，epoch 增长，native host 继续拒绝旧 agent 输入；进行中的输入必须先完成同一 flock 临界区，之后人才能接管。
- release 只能操作精确 viewer+session；Mac 本地“归还”也走同一原子写并保留原任务关联。归还后唤醒仍存活且 generation 相同的原 gate，继续原工具轮次，**不 self-POST 一个新任务**。
- 截图等待后可以读取新画面；已经计划好的 click/type 在人工改变桌面后不能直接重放。gate 返回 `desktop_changed; screenshot_required` 给同一 agent，下一步重新截图再决定操作。原任务仍在，只重新观察。
- 待恢复 work 若已取消/完成/代际变化，只清理关联，不唤醒。重复 release 不重复执行工具。取消等待不执行任何坐标动作。
- human 心跳过期停止人端输入；默认不自动让 agent 在用户仍操作时继续。允许原设备重新接管；过期的另一设备租约可被明确的新 acquire 接替，但不能被旧 heartbeat/release 覆盖。当前 acquire 对过期 foreign viewer 永远拒绝的漏洞一并修复。
- runtime 崩溃后原 Event/Future 不存在，遵循 Hermes unknown outcome 处理，不把持久化 waiting 行当作批准或自动重放副作用。界面显示“任务需要确认”，新聊天仍可独立工作。

## 7. 实施文件归属

实现 agent（Python + Swift 合同/store）：

- `Apps/MacApp/Runtime/conversation_store.py`、`personal_agent.py`：work 路由、上下文、幂等、投影、取消、所有 roots 的完成回执。
- `Vendor/HermesAgent/gateway/session_api_turn.py`、`session_queued_controls.py`、必要的 claim validator：steer-only 安全 seam；`platforms/api_server_authority_runs.py` 的可选产品投影。
- `Vendor/HermesAgent/agent/tool_executor.py`：精确 owner 的产品 computer gate；仅小接点，通用 runtime 默认行为不变。
- `Vendor/HermesAgent/tools/async_delegation.py`：精确取消 helper；必要的 process snapshot helper。
- `Apps/MacApp/Access/desktop_control.py`、`Desktop/DesktopControlHost.swift`：同一租约附加关联/归还/过期重接；不改 Cua 驱动。
- `Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/SharedConversation.swift`、run 模型、`RemoteTaskStore.swift`：可选字段、控制请求、幂等 pending/cancel、保留 journal。

根 agent（UI + 独立验收）：`Apps/ClientUI/RemoteTaskRecoveryView.swift` / `RemoteTaskControlsView` 的两端共用入口、必要 composer 绑定。字段以上表为准；不做独立 task 页面，不碰 `.pen`/Models/main。

## 8. 必须通过的验收

使用现有 `Tests/AgentRuntime/nonblocking_chat_smoke.py` 的真实 Hermes + scripted model + 工具屏障路径，不能只 mock PersonalAgent；扩充 `test_personal_agent.py`、`test_desktop_control.py` 和 Swift 包测试。

当前真实 Beta native IPC 权限为 `screen=false,input=false`。本轮不要求用户开权限；电脑验收使用真实 Hermes + 本地 scripted model / Unix IPC fixture 验证互斥和归还状态，不声称已完成真实屏幕读取、鼠标或键盘闭环。

1. A 原生 approval 等待、B 普通 new 得到最终回答；A 的副作用 marker 仍不存在。普通“好的/继续”作为 B 不能批准 A。精确批准 A 后只执行一次；clarify 同样验收。
2. B 能读到先前可见聊天；A 未批准动作没有变成 B 的授权；两者各自完成结果回到同一 messages cursor。压缩后的 native alias 仍归同一 work。
3. A/B 同时运行，补充精确到 A；代际变化、A 刚完成、尚无 adopted agent、pending control 都返回409且草稿保留。强制 steer 在 transfer 后未消费，恢复后也不得成为独立任务。
4. 同一 operation 重发只产生一次 user 消息/一次 native admission。升级 schema1 本地缓存，旧未回执请求/旧 API body/旧手机 run.sessionID 校验保持可用。
5. 两个进程/两项 delegation 有不同标题和 origin；取消一项只影响它。kill 不完全仍显示可管理状态；取消完成竞态不改写真实结果。列表刷新不吞原生完成通知。
6. 整 work 取消与新 child dispatch 竞争：fence 阻止逃逸；终态后不会被 completion wake 复活；另一个 work 能正常完成。
7. agent A 操作时人接管，旧 epoch 输入确实拒绝；B 文本聊天可完成。归还后 A 重新截图、继续且不重复旧 click。另一个 agent work 不可抢占 A 的计算机序列。
8. 人工租约重复 release、过期 heartbeat、另一手机旧 lease、A 已取消、runtime 重启分别测试；无错误授权、无自动重放副作用、无永久 foreign-expired 锁死。
9. 断网时取消按钮显示请求中/可重试，不伪造已停止；重连按幂等 operation 对账。手机退出后服务端仍执行，恢复补读所有状态。
10. 手工 UI 验收：两端同一任务标题、等待卡可回答/取消、加载在按钮内、composer 可输入、任务区不挤走正文；无独立巨型任务面板。

## 9. 公开源码依据

- [Rakazo run-state / 哪些等待占住队列](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/core/src/run-state.ts#L9-L29)
- [sendUserMessage：clientNonce、消息/run事务、显式允许并行](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/db/src/events.ts#L405-L528)
- [pauseRunForInput：结束 attempt 并释放租约](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/db/src/events.ts#L1135-L1218)
- [pauseRunForTakeover / finalizeComputerControlRelease](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/db/src/events.ts#L1220-L1442)

借鉴的是 work 与可见聊天分离、精确控制、等待/归还状态和事务回执；不移植 Rakazo Pi、Postgres、云沙箱或多 bot 框架。
