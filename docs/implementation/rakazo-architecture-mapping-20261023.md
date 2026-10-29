# Rakazo → MoMoAgent 架构映射与实施合同

状态：源码研究与实施交接；本文没有把待实现能力记为已完成。用户于 2026-10-23 要求先由架构 agent 完成源码阅读，再由实现 agent 改造；本轮按此顺序执行。

## 1. 源码基线与结论

- 官方仓库：`elie222/rakazo`，本轮固定 `5ef4476d96e0eea64d3b27833ff7f2b201f918da`。先通过 GitHub connector 读取 `git/ref/heads/main`，再以本地只读 checkout 批量追踪调用链。
- 相对上一轮 `b088a4c8b5bd694d78b56cf9d87e11d83cccb72f` 新增 3 个提交：MCP OAuth 故障文案、手机密码可见性、移除机器人头像风格；本文涉及的核心编排路径未变。
- 源码 checkout：`/Users/syh/Documents/Codex/2026-10-21/jie-he/research/rakazo`。它是研究材料，不是 MoMo 的生产依赖。
- MoMo 保持 `codex/hermes-app-20261021`，保留 Hermes、嵌入式 TailscaleKit、SwiftUI 客户端、原生记忆与来源同步。参考的是职责、数据归属、状态机和恢复方式，不引入 Pi、Postgres、Graphile Worker、多 bot 或云电脑为本版前提。

核心变化：**手机和桌面只提交意图与展示状态；Mac 的持久服务负责对话、工作跟进和结果投递；Hermes 负责推理、记忆、工具与执行。** 连接断开、窗口关闭、UI 不刷新，都不能成为完成事件是否继续处理的判定条件。Mac 进程停止或系统睡眠仍不能执行。

## 2. Rakazo 的实际分层

```text
Web / Electron / Expo / messaging
  └─ API 身份与授权 + 共用产品合同
       └─ Thread / Message / Event / Task / Run / Attempt
            ├─ 持久 job + worker + reconciler
            ├─ Pi AgentRuntime（模型循环、工具调用、同轮 helper）
            ├─ CloudAgent / bot-message（跨轮异步工作和回传）
            ├─ SandboxProvider / 本机授权桥 / MCP
            ├─ memory / history / routines
            └─ 最终消息与未读 → 通知 provider
```

`apps/worker/src/index.ts` 将 `PiAgentRuntime`、`createRunExecutor`、`GraphileJobPublisher`、worker handlers 和 reconciler 装配起来；不是手机自己运行 Pi，也不是 computer sandbox 执行 Pi。`SandboxProvider` 只提供电脑生命周期、观察/输入、命令、文件等能力。[worker 装配](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/apps/worker/src/index.ts#L118-L309) · [provider 合同](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapter-kit/src/interfaces.ts) · [computer runtime](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/docs/computer-runtime.md)

### 持久对象并不相同

| Rakazo 对象 | 源码语义 | MoMo 对应与取舍 |
|---|---|---|
| Bot | 持续身份，一个可见 Thread；角色/记忆/电脑归此身份 | 既有 `assistant_id` 表示一个 MoMo |
| Thread | 可见对话；消息 seq、事件 seq、lastReadSeq、压缩水位 | Mac 保存稳定 `conversation_id`；与 Hermes 物理 session tip 解耦 |
| Message | 用户/助手/卡片内容；`threadId+clientNonce` 唯一 | 服务端持久消息；客户端 operation UUID 是重试身份 |
| Event | Thread 内单调 seq 的产品变化 | 增量事件/消息游标；推送通知只叫醒读取，不是消息来源 |
| Task | 一次 prompt 的工作记录 | 原始目标/执行关联；不能用本地列表代替服务端归属 |
| Run | 一轮工作，trigger、sourceMessage、状态、lease | Hermes admission/run，关联用户输入或可信完成事件 |
| Attempt | 同一 run 的执行尝试，fence 区分旧 worker | 复用 Hermes runtime epoch / execution generation，不再造锁 |
| SteeringMessage | 已保存、可被运行领取的补充；未回答可进入 continuation | 先持久化再交给当前任务；已传递和已回答分开 |
| CloudAgent | 外部任务的 operation key、remote id、generation、wakeGeneration | Hermes async delegation / process registry 的真实任务身份 |
| ExternalEffect | 外部写入意图、idempotency key、结果、review | 复用原生工具审批和执行结果；不因重连重放未知写操作 |
| Routine | 显式计划 prompt / 变化监测 | 既有 Hermes cron/授权调度；转录更新不是自动执行授权 |

[schema 实际定义](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/db/prisma/schema.prisma#L454-L876)

Rakazo 的 `Task.status` 也会在 `finalizeRunOnce` 随该 run 结束，并不是能证明所有长期用户目标完成的万能账本。我们必须区分 **执行者完成、Hermes 已核对/续跑、已向用户回复**；不能看见 LLM run terminal 就把仍在后台的事情标成“已完成”。

## 3. 三条回传链路不能混为一谈

### 3.1 同轮 subagent：结果直接回到父工具调用

`pi-runtime.ts:executeSubagent` 在父轮中 await helper，完成后把 helper 的回答作为工具结果返回；它明确不是独立 bot chat。子代理不能自行向人发消息，不能把子代理结果标成用户指令。此路径不需要额外生成后台 wake。[实现](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/pi-runtime.ts#L1593-L1904) · [来源标签测试](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/pi-runtime-helper-framing.test.ts)

### 3.2 bot-message：持久消息投递，结束后再回传

`messageBot` 在事务内保存收件消息、发件回显、Task、Run 和事件，提交后才通知订阅者并 enqueue job。`returnBotMessageOutcome` 使用 `auto-outcome:<runId>`；只有显式 `intent=result` 抑制自动最终回报，中途 `status` 不算完成。`botOutcomeReturnedAt` 仅在成功或明确无需投递后更新。reconciler 查找未回传的终态 run 补投递。

[投递与最终回传](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/bot-messages.ts#L104-L411) · [漏投递补偿](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/job-reconciler.ts#L274-L359)

### 3.3 CloudAgent：远端执行状态 → 唯一续跑

`pollCloudAgent` 先存 dispatch intent，再调用 provider；以 version+leaseToken 防止并发 poll 覆盖。`finishPoll` 在一个事务中更新真实结果、卡片事件，并在 `wakeGeneration < generation` 时创建唯一 continuation run。wake 只含本地任务 ID 和状态，让 Agent 用工具读结果，不把 provider 文本注入成高权指令。事务提交后 job enqueue 失败，由 reconciler 恢复。

```text
intent 已存 → 外部派发 → 记录 remote id → 观察真实终态
  → 原子登记该 generation 的 wake run → enqueue / reconcile
  → Agent 读取结果 → 检查/继续 → 持久最终消息 → 通知
```

取消有独立 `cancelRequested`；HTTP 成功不等于远端已经停止。响应丢失时先查询远端身份/运行列表，不盲目重发。[实现](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/cloud-agent-poll.ts)

MoMo 最接近第三条的是 Hermes 的 `async_delegations` 与 background process 通知；不是再把手机变成 job worker。

## 4. 消息继续交互与等待卡片

`sendUserMessage` 先以 clientNonce 去重，再在事务中保存 Message。可对话 run 在执行时接受 steering；routine、webhook、bot-message 等来源有不同回传归属，不能吞掉用户的新问题。claim 在运行 lease/fence 下领取，记录消息序号水位。run 结束或暂停时创建未被回答的 continuation，失败后已回答的补充不会重复回答。[消息与 claim](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/db/src/events.ts#L393-L644) · [finalize 与 continuation](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/db/src/events.ts#L1523-L1763)

Rakazo `waiting_input` 不持有新聊天队列；`waiting_takeover` 仍持有电脑控制相关队列。审批卡片不会因为下一条普通消息就被批准；普通自由文本仅能回答适用的 question ask，approval/secret 有独立路径。[状态机](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/core/src/run-state.ts) · [问答与暂停](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/db/src/events.ts#L1072-L1188)

MoMo 要达到的交互：真实模型先短答，然后委派长工作；用户可继续聊天、追加要求和取消。三点只表示当前对话等待回复，不覆盖整个后台任务周期。任务进度、待确认卡片、断线状态各自表达，不用一个永久转圈概括。

## 5. MoMo 当前根因与可复用能力

| 现有文件 / 路径 | 已具备 | 缺口 / 不能误用 |
|---|---|---|
| `Packages/MoMoAgentAgentClient/.../RemoteTaskStore.swift` | 本地 durable outbox、operation UUID、回执恢复、run 观察 | 各设备随机 `momo-UUID`；可见聊天由本地 task 拼接；`receiveBackgroundResults` 依赖前台刷新的隐藏 POST |
| `SessionMessages.swift` | 能读 Hermes transcript | 只有 id/role/display_kind；固定 latest 100，无正文和历史续读 |
| `Apps/ClientUI/ChatRenderSnapshot.swift` | 两端共用渲染 | 只把本机 task/reply 变成聊天，服务端产生的新回复不可自然出现 |
| `Apps/MacApp/Access/access_server.py` | 设备配对鉴权、固定转发、撤销和 SSE | 不是任务所有者；新产品路由和 device read cursor 需接入；不能开放任意上游路径 |
| `Access/rtc_transport.py:permitted_route` | 所有传输共用 allowlist | 加接口必须同时更新这里；当前仅允许有限 transcript 查询及 run/stop |
| `gateway/session_api_turn.py` | API admission FIFO、持久重试身份、恢复、generation | 不等于可信后台 completion 身份；正常 API user turn 不能冒充系统来源 |
| `gateway/run_notifications.py`、`wake.py` | 原生任务结果、producer identity、delivery claim | API async delegation 故意只写 delivery row；其他 process 通知使用 self-POST，均不够作为 MoMo 的统一产品闭环 |
| `gateway/session_automation.py` | 非人类 producer、FIFO、去重、恢复 | `snapshot_automation` 明确拒绝 `Platform.API_SERVER`；不能直接传 API source 调用 |
| `gateway/session_completion_notes.py` | local completion 在无 viewer 时存 note | 仅换成 LOCAL 也不会得到手机离线后自主回复；禁止假挂 viewer 绕过 |
| `gateway/session_queued_controls.py` | ticketed steer transfer，未消费回队、generation fence | 当前仅 interactive LOCAL source/plain text；不能直接拿 API payload 套用 |
| `gateway/platforms/api_server_runs.py` | run/approval/clarify/stop/steer | `/steer` 的直接 agent.steer 回执不是持久新消息；手机尚未暴露完整 control 合同 |
| 原生 `MEMORY.md` / `USER.md` / session_search | 持久记忆、压缩、检索 | 记忆条目不是 scheduler，不代表任务会醒来 |

Hermes 的安全默认不能被简单删除。尤其 `wake.py` 关于 pending human-confirmation 的保护是执行边界，不是多余分支。

当前 Swift `AgentRun` 只解码 run/session/status/output/error；`RemoteTaskStore.reconcile` 把 `waiting_for_approval` 排除在已知状态之外，会显示 unknownOutcome。服务端保留审批但不给客户端入口，会把用户卡住，因此本次改造必须同时补齐控制模型和 UI，不能只加后端 gate。

Mac 当前 `DesktopModel.shutdown()` 会 terminate agent/access，显式退出 App 会停止服务。关闭手机不应停止任务；显式退出 Mac 后继续执行尚不是现有能力。本轮不要悄悄把应用变成未经展示的常驻登录项；需要常驻服务时单独做可控运行与停止入口。

## 6. 目标合同：一条可见对话，原生执行队列

### 6.1 所有权与最小新增数据

产品数据与执行数据分开，但不建立第二套模型执行器。建议 MoMo 产品 store 放在自己的 runtime 目录，原生 admission 仍在 Hermes `state.db`；跨库用稳定键与 reconciler 补偿，不假装有跨库原子事务。

| 产品记录 | 必需字段 / 不变量 |
|---|---|
| conversation | `id, assistant_id, instance_id, hermes_root_session_id, created_at`；每 assistant 一条默认主对话；压缩只改变 tip |
| message / event 投影 | `id, conversation_id, seq, role, kind, content/blocks, source_session_id, source_message_id, operation_id?, run_id?, created_at`；同来源行唯一；写入和 cursor 更新原子 |
| completion receipt | `event_key, producer_kind, producer_id, generation/incarnation, owner_conversation_id, origin_run_id?, source_message_id?, state, admission_id?, reported_message_id?, next_attempt_at, last_error`；event_key 唯一 |
| delivery/read | device 的 `received_seq` 与用户的 `read_seq` 分开；收到不是已读。已读只由看见内容后的显式确认推进 |
| notification outbox（启用系统推送时） | `delivery_id, device_id, conversation_id, message_id, state, attempt, next_attempt_at`；消息落库后才入 outbox；token 不进入日志 |

能直接稳定映射原生 message ID 的字段不复制另一份推理历史。产品投影只包含可见消息与必要任务状态；原始 transcript、工具参数、完整结果继续在 Hermes/资料库。`source_message_id` 不假定跨 profile 全局唯一，唯一键带 session/instance。别用内容相等去重：用户可以连续说两句相同的话。

### 6.2 客户端 API（建议名称；实现时可在同一合同下保持已有命名）

| 接口 | 合同 |
|---|---|
| `GET /momo/v1/conversation` | 返回 stable conversation/root identity、能力标志、最新 seq、read seq；仅受信同一 Mac/assistant；不存在则服务端原子创建 |
| `POST /momo/v1/conversation/messages` | `operation_id, content, target_work_id?`；先持久化，返回 `message_id, seq, disposition(queued/steering), run/admission_id?`；同键不同内容 409，同键同内容回原回执 |
| `GET /momo/v1/conversation/messages?after=<cursor>&limit=N` | 按服务端稳定 seq 升序，`data,next_cursor,has_more`；客户端必须读到 has_more=false；不跳过抓取期间新行 |
| `GET /momo/v1/conversation/messages?before=<cursor>&limit=N` | 历史续读；边界稳定，不能仅 latest100 后宣称已完整同步 |
| `GET /momo/v1/conversation/events?after=<cursor>` | 在线 SSE 可选，复用现有传输；事件持久投影补齐为准，不以连接是否存在决定执行 |
| `POST /momo/v1/conversation/read` | `through_seq` 单调推进，不能超过已存在可见消息上界；设备可分别保存接收位置 |
| 原生 run controls / MoMo 映射接口 | stop、clarify、approval、resolve unknown 必须带精确 run+generation+prompt id；只开放已支持动作 |

能力建议：`shared_conversation`, `server_owned_completion`, `durable_steering`, `system_push`。客户端在 server_owned_completion=true 时彻底停止旧的 `receiveBackgroundResults` 隐藏提交；不能让新旧策略并跑。旧服务不支持时保留旧日志可读并提示升级，不把客户端提交伪装服务器闭环。

HTTP 和 Tailscale/SSE 是运输。所有新路由同时更新 `permitted_route`、HTTPS/私网转发、RTC（若仍启用）和拒绝用例。设备 identity 从配对授权结果派生；客户端自报 `device_id` 不能授予读取、审批或推送接收权。

控制数据需解码 `pending_controls`、`admission_id`、`execution_generation`，而非只判断 status。原生 authority 的审批请求体严格为 `{"request_id": "<prompt_id>", "execution_generation": N, "choice": "once|deny"}`；澄清为相同身份加 `answer`，分别发 `/v1/runs/{id}/approval` 和 `/clarify`。先实现本次允许/拒绝和明确回答，只有服务端 choices 允许且产品有意提供时才出现更宽授权。卡片保存审批对象和 generation，重试前重新获取当前 pending controls；过期/已回答卡片显示已失效并刷新，不提交到别的 run。等待审批/输入是可处理状态，unknown 才是结果不确定需核对。

### 6.3 可信 API completion admission：建议的 Hermes 扩展 seam

不是 HTTP self-POST，也不开放一个任意客户端可设置的 `internal=true`。MoMo 启动器明确启用其专用集成，通用 Hermes 默认行为保持原样。

1. 在 `GatewayRunNotificationsMixin._self_post_api_server` 的受信 producer 分支，MoMo handler 接收原生 `evt`；继续使用 `_completion_delivery_identity` 的 delegation ID / process ID+started_at，区分 interim failure notice 和 batch final。
2. 先复用 `persist_delegation_delivery` 保存原生结果及 source row；然后持久写 MoMo completion receipt。事件正文是资料，不能作为新的用户授权。receipt 的 owner 必须由真实原始会话/委派记录证明，不能从 provider 文本取值。
3. 新增私有函数，例如 `admit_api_completion(adapter, receipt)`：在 owning authority loop 上执行，使用 `authority.logical_owner` / `restore_api_session` / `_admission_gate` / `tracked_write` 和 `admit_session_input`。稳定 `request_id = momo-completion:<event_key>`；不得随机生成每次不同的 ID。
4. 使用独立受信 payload descriptor（例如 `api_automation_v1`），标明 producer、owner、原结果引用、去重键和 MoMo 授权依据。只由服务器创建；客户端 `/v1/runs` JSON 不接受它。`principal_id` 区分人类输入与自动结果；不能靠 `turn_author.is_bot` 一个展示字段来授权。
5. 最小原生修改范围：`session_api_turn.py` 的准备/校验/恢复；`session_ingress.py` 的来源标签和执行上下文；`session_authority.py` preclaim 的再校验；通知入口调用。用独立 helper 文件承载 MoMo 规则，避免把业务分散进 TurnRunner。payload 不重写已有用户审批策略或 runtime model settings。
6. 入队时和 claim 前都检查：origin 仍存在、owner 未清除/撤销、非手动取消、不在 unknown execution 后、没有对同一事项尚待决的 approval/clarify。暂停时 receipt 保留 pending/blocked，不丢弃。新普通聊天不是对待确认操作的同意。
7. FIFO 和 restart recovery 继续由 Hermes 保证。需要扩展 API recovery 对该受信 principal 的识别；只写新 admission 却没有启动时恢复扫描，仍是不完整实现。
8. 启动一轮时从原生历史读取真实结果，提示 MoMo 判断继续、澄清或报告；内部提醒标为 `internal_notification` / MoMo completion kind，不显示用户气泡。结果报告在 native turn settlement 后映射到同一 conversation。
9. `admitted` 只是成功入队；`reported` 要有真实助手消息 ID。started 后崩溃仍 unknown，禁止再创一个新 admission 自动重复执行。queued 或入队回执丢失则按同一 event key 找回。

最终源码核查后，可落地的最小 seam 如下。函数名为新增建议，已有函数与位置已经核实；这不是已验证运行的实现：

| 调用点 | 最小接入与必须保留的保护 |
|---|---|
| `run_notifications.py:_self_post_api_server`（784） | 仅 MoMo 集成启用且 producer/owner 验证通过时交给 completion handler；普通 Hermes 保留当前行为。async delegation 继续先存 delivery；process/watch 用自己的原生结果记录，不把全部事件误装成 delegation。返回成功代表结果与 receipt 已持久接管，不要求当下完成模型回复。 |
| 新 `session_api_completion.py:admit_api_completion` | 从绑定的真实 adapter 获取当前 serving authority；校验 assistant/profile/root 和 receipt 来源；使用 `logical_owner` 后恢复已有 API binding，不允许 receipt 创建任意陌生 session。构建白名单 `api_automation_v1`，以独立 principal 和稳定 request ID 调用 `admit_session_input`，通过 `tracked_write` 与 `_admission_gate` 管理关停/提交，再 `_schedule(ref)`。只允许服务端 Python 调用。 |
| `session_authority.py:_claim_next`（1002，API 分支1059） | 对 automation row 调用新的 **row-aware** `check_api_completion(authority, ref, row)`，核对 principal、descriptor、可信来源和状态；不能只把 payload 送入现有 `check_api_turn`。保留 unknown 阻塞、head 精确匹配、mutation/claim gate、epoch/generation；等待校验期间若行已取消，不能把通过的校验借给后继行。 |
| `session_api_turn.py:check_api_turn`（48）与 `prepare_api_execution`（474） | 严格识别新 descriptor，settings 取原 session 已存配置，历史取原会话；不允许 completion 提交 model/route/credentials 或普通用户 turn_author。`prepare_api_execution` 返回已验证的资料引用与来源标签。原 `api_turn_v1` 路径不放宽。 |
| `session_ingress.py:execute_admission`（227）与 `row_turn_author`（213） | 新 descriptor 恢复为内部结果事件，保留 parent/work 与 trusted owner metadata，内容本身仍是低信任工具资料；复用 API execution、TurnRunner、pending_results、原子 settlement。后台提示不成为用户气泡或新的授权。 |
| `session_api_turn.py:recover_authority_api_turns`（328） | 现查询只扫描 `principal_id='api' AND status='queued'`，必须补扫描新受信 principal；逐 row 使用对应校验，unknown 不调度。独立 reconciler 同时补“receipt已存但admission尚无”与“admission已存但receipt未关联”两种跨库窗口。 |

实施时不要直接复用 `_admit_api_payload` 后改 principal 字符串：它还通过 `_one_target` 固定查询 `principal_id='api'` 并写入 API settings，必须给新 principal 明确的唯一键/目标校验，不覆盖用户 settings。来源验证要以原生 delegation/process 的持久 owner 记录和允许的 MoMo binding 为证；只知道 session ID、文本中的“已完成”或一个可伪造 JSON 字段都不足以授权。pending approval/clarify 的检查也需在 claim 前重验，且不能用自动 completion 清除控制请求。

**迁移前已有完成结果**也需纳入服务端扫描：按原生 delivery rows/async delegation durable records 找未消费事件，并与旧 client-generated continuation 的 `backgroundMessageIDs` 或可验证 provenance 对照。不能仅依靠新通知 hook，否则升级前已完成未回复的事项会永久漏掉；也不能对全部历史 delivery 重新唤醒。

### 6.4 能继续聊天的实现边界

正常路径保留 Hermes 原生 async delegate：主对话只做短回应与协调，长工作在委派执行里；同一可见 conversation 可以关联多条执行记录。新消息先持久提交，再按明确目标作为补充或排入短对话，不取消现有工作。

要声称与 Rakazo 的 durable steering 等价，必须把 API 的已入队用户消息安全转换为 ticketed steer，复用 `session_queued_controls.py` 的 transfer / generation / 未消费回队规则。现有 `/v1/runs/{id}/steer` 的裸文本接收不是这个保证。转换时原消息/回执身份保持，不能同时留下独立 queued turn 再回答一次。

待确认时不能通过新自动完成事件代替人点击批准。Hermes 当前 API approval 会阻塞所属执行；要让独立问题继续回答，必须把审批停在所属工作会话/attempt，不挂住唯一主对话，或实现真正可恢复的 input pause checkpoint。不能只在 UI 解禁输入框就宣布“等待确认不阻塞聊天”。原生 delegate 子代理禁止 clarify、不能直接与用户聊天；需要用户输入时回传给父协调者，并持久保留原 work 和控制目标。

如果本次实现未完成上述独立问答/审批隔离，必须标注能力 false、保留正确排队，并将该验收列为未完成；不得取消审批或创建可执行的并行会话来绕开 gate。

推荐实施取舍：本次先完成全部持久接收、共享历史、服务端完成续跑、审批可响应和长任务 delegate；随后在同一改造中接 API ticketed steering 并运行竞态用例。若 native 受限导致 steering 不能安全完成，要把它作为明确剩余项上报，不能用现有直接 `/steer` 宣称完成。`disposition=queued` 表示已接收待处理，只有确认原生 transfer 成功才可显示“已补充到任务”，二者不互换。

### 6.5 旧数据兼容

- schema1 的 `tasks.json` / `desktop-tasks.json` 原样保留可恢复；草稿、旧 session 和未知接收结果全部保留。
- 旧未回执操作继续使用原 `operation_id + session_id` 核对，绝不改成 shared session 再 POST。
- 新消息绑定服务端 shared conversation。旧会话可作为历史记录访问，不自动把两端私有日志拼成一个伪造时间线，不删除或隐去用户数据。
- 压缩使用 logical root 查 continuation tip；不要用 `snapshot.session_id != original.sessionID` 的现有严格校验拒绝合法 compression alias，但也不能放宽到接受任意他人 session。
- 产品投影记录 origin root/tip/message ID，按原生压缩 lineage 去重；新增投影扫描若只按全库最大 message ID，可能漏掉延迟回写或压缩祖先，必须固定 ownership 与可续读范围。

## 7. 网络、电脑、记忆与通知：借鉴到哪里

### 网络

Rakazo mobile `endpoint.ts` 对公网要求 HTTPS，允许 localhost/LAN/100.64.0.0/10 的 HTTP；用户配置 server URL 后探测 `/rpc/health`。源码没有证明双端内置 TailscaleKit。MoMo 已有的 Tailscale 登录→扫码→Mac 确认保持，不恢复 HTTPS 证书教程或临时隧道。[手机连接代码](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/apps/mobile/lib/endpoint.ts)

### Computer use

Rakazo `host-computer.ts` 保存本机 token 与明确 consent，只向 app 管理的本地 backend 激活；远端服务器登录不会自动得到当前电脑权限。view/control 分离、lease fence、未知动作先观察再决定重试值得沿用。MoMo 保留 Hermes→本机 MCP→cua-driver，系统辅助功能/屏幕权限缺失时如实返回不可用；本轮不能把未授予权限说成打通。[本机桥](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/apps/desktop/src/host-computer.ts)

### 记忆和上下文

Rakazo 区分 durable history、runtime context、scratchpad 和 routine；scratchpad 明确不是 scheduler。MoMo 继续原生 MEMORY/USER/session_search，近期转录仍按原始证据注入，补读有稳定来源/分页；健康未同步仍显示 unavailable。不要为完成事件再造事实记忆或让记忆条目承担任务唤醒。[scratchpad](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/scratchpad-context.ts) · [上下文投影](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/runtime-context.ts)

### 系统推送

Rakazo 先 `finalizeRun` 持久最终消息/未读，再 `notifyRun`→Expo。token 与登录 session 绑定；缺 token、被 Expo 接受、receipt 错误不同。普通 `notifyRun` 失败默认只记日志；不要误报为完整持久推送 outbox，MoMo 若需要跨重启通知重试应自行加小 outbox。[发送顺序](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/executor.ts#L8394-L8458) · [普通通知失败处理](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/executor.ts#L8805-L8858) · [Expo token/receipt](https://github.com/elie222/rakazo/blob/5ef4476d96e0eea64d3b27833ff7f2b201f918da/packages/adapters/src/expo-push.ts#L456-L577)

MoMo 原生 iOS 接 APNs，不引入 Expo。需 Beta topic/entitlement、设备 token 注册与更新、配对撤销时解绑，以及持有开发者 APNs 凭据的通知服务。不能把开发者私钥分发进每位用户的 Mac。通知 payload 只含 opaque conversation/message/delivery ID 与简短提示，正文经现有受鉴权通道读取。未部署通知服务时 `system_push=false`，仍必须完成离线保存与回前台补齐，不能用 SSE 冒充锁屏推送。APNs 接受不等于用户已读，也不能依赖静默推送唤醒手机才能处理任务。

## 8. 建议改动清单与实施顺序

以下为职责划分，新增文件名允许实现者按现有结构调整；不能只做一半调用方。

1. **产品 store/路由与原生桥**：新增 MoMo conversation/coordinator 模块，装配进 `momo_agent.py` 的 Mac 运行服务；稳定默认对话、消息投影、completion receipts；最小 Hermes integration seam 与恢复；保持泛用 API 默认安全行为。
2. **网络边界**：`access_server.py` / `pairing_store.py` 派生受鉴权设备；`rtc_transport.py` allowlist 覆盖新接口；直接 Mac loopback 和手机路由返回同一产品合同。
3. **Swift 合同与日志**：`AgentConnection/AgentModels/SessionMessages/AgentClient/RemoteTaskStore` 添加 shared conversation/cache/cursor，区分 outbox 与 timeline；兼容 schema1，关闭客户端完成唤醒；支持必要 control 状态，未知状态继续可核对。
4. **两端呈现**：`ChatRenderSnapshot` 及 Phone/Mac store 入口改为服务端消息+未确认 outbox 合并，稳定消息 ID；保留 Dots 三点、短文案、输入/重试和已有录音UI；不新造独立计划页。
5. **任务补充/审批**：完整实现并测试 ticketed steering 或明确 capability 降级；先保证审批不被越过，再实现待确认工作和主聊天分离，不能拿双执行绕过控制。
6. **通知**：有服务端配置时接持久通知 outbox；没有时完成可测试 provider seam 与 false capability，明确未部署。通知可失败，消息不可丢。
7. **文档/版本/交付**：更新 `Vendor/HermesAgent.UPSTREAM.json` 的本地补丁记录、实施说明及HTML方案；测试通过后只构建 Beta。安装前后双校验正式/Beta 身份与版本，绝不推 main。

## 9. 验收合同

现有 `Tests/AgentRuntime/nonblocking_chat_smoke.py` 已有真实 Hermes + 本地脚本模型 + MCP 长任务屏障 + Swift probe，适合作为主线；扩展它，不把关键断言替换成全部 fake queue。

| 用例 | 必须证明 | 参考源码测试 |
|---|---|---|
| 双端 shared thread | 两个独立日志 bootstrap 同一 conversation；A发送，B读同一 message ID | Rakazo events/nonce；MoMo 新 Swift tests |
| 手机离线完成 | 停止所有客户端刷新→释放 MCP屏障→Mac 自主出现最终助手消息→两端回来补齐 | `cloud-agent.postgres.test.ts`175、214；现有 nonblocking smoke |
| 重复完成 | 同event投递/重启/丢ACK，只有一个逻辑 continuation，工具副作用一次 | cloud-agent175、194、508；bot-messages544、592 |
| 中途进度后最终 | “已启动”“处理中”不能消费最后报告；最终结果仍由父代理说明 | bot-messages665、705 |
| 入队失败补偿 | receipt已存/job未投、admission已入/receipt未绑，重启后找同一身份 | cloud-agent214；job-reconciler tests |
| started崩溃 | unknown阻止自动重放，保留待核对；不重新执行外部写操作 | Hermes `test_api_authority_retry.py`、`test_unknown_automation_settles.py` |
| 审批/澄清 | completion不能批准；普通聊天不能代替明确approval；待确认事项保留精确generation | Hermes `test_api_authority_controls.py`、`test_api_pending_daemon.py` |
| 补充竞争 | 接收后当前run刚结束、steer未消费、重启与重复提交均不丢不双答 | Rakazo `steering-replay.postgres.test.ts`147、156、186；Hermes queued controls tests |
| 取消 | stop ACK不等于已停；旧completion不能复活取消事项；故障有可核对状态 | cloud-agent438、524；MoMo task tests |
| 消息分页 | >100条、并发新消息、重复页、空页、游标持久写失败、压缩lineage都不漏不乱 | Rakazo eventsAfter/followThreadEvents；新客户端与服务端用例 |
| 旧日志迁移 | schema1草稿/原session/未回执ID保留，迁移不产生新POST，旧聊天可查 | 现有 ConversationDeliveryTests 扩展 |
| 撤销/隔离 | revoked设备不能读、控或收推送；伪造内部completion字段拒绝 | cloud-agent281、299；MoMo pairing/allowlist tests |
| 通知失败 | 消息已保存；push retry不触发重新推理；无token不标送达 | Expo tests286、1018、1109；MoMo provider fixture |

Rakazo 测试是阅读依据，本轮没有运行其全套集成测试。MoMo 实现完成后需运行上述适用测试以及原生 session/approval/automation 回归，不能仅以 Swift 编译或接口返回200代替行为验收。真实账号跨网、iOS锁屏推送、Mac睡眠恢复与真实computer-use权限验证分别记录，不与合成POC混写。

## 10. 交接前审查清单

- 任务完成的责任已从前端刷新移到 Mac 服务；两端读同一条结果。
- 所有 accepted、running、unknown、reported、notified、read 各有证据，命名不夸大。
- 原生 admission/generation/approval/压缩边界仍生效；没有任意 self-POST 或 fake viewer。
- 没有重复的客户端唤醒，也没有把工具文本写成新用户授权。
- 旧日志与草稿不丢、未知副作用不重放、分页不静默截断。
- 系统推送和待确认期间独立聊天按实际完成度披露，不把接口预留写成已上线。
- 当前正式 App、用户数据、`.pen`、`Models`、main 均未因架构改造被修改。
