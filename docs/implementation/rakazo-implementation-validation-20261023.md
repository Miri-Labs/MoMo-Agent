# 持续对话实现与验证（2026-10-23）

实施依据是 [最终源码映射](rakazo-architecture-mapping-20261023.md)，不是把 Rakazo 的 Pi / Postgres / 多 bot 平台引入应用。以下是分支代码状态，最终安装和独立验收另见文末；模拟测试不代替手机实机验收。

## 已实现

- Mac 生成持久 conversation 身份。双端采用 schema 2 缓存，保留 schema 1 草稿、原 session 和未回执 operation；新消息不会在 discovery 失败时回退旧提交入口。
- 用户意图先写 product inbox，再用稳定 request ID 接入 Hermes 原生 FIFO。消息按 cursor 分页，助手消息使用 native admission + occurrence 身份，保留同文不同次回复和压缩前历史。
- 完成事件先保存正文、原生 producer 和原 admission 来源，再确认接收。即使 native transcript 因审批/澄清处于 active lease，也不会丢失 receipt。Mac 在可写时保存原生 delivery，按私有 principal 入原生 admission；结果完成后生成的模型回复落库，receipt 才标 reported。
- 手机和桌面不再创建 hidden completion POST。原生 run 状态、审批/澄清、后台 delegation 工作状态从服务器回读；LLM run completed 不代替后台工作/最终报告状态。
- 显式“补充”绑定目标 run 与 generation，先入 durable queue，再使用 Hermes ticketed steer transfer；无法安全转交则留在 FIFO。没有裸 steer 注入。
- 控制使用确切 prompt ID / generation。unknown 不自动重放，需用户核对后解除原生阻塞。普通信息仍可接收；等待确认时真实排队。
- 旧 session 的完成结果可以归入共享对话；仅凭结果后出现普通人类消息不会判定已消费。旧 journal 提供具体 message IDs → 原 native continuation 的绑定，经服务器核对后防止重复激活。
- 通知 outbox 与消息、已读位置分离，有可测试 provider seam 和 retry；未配置 APNs 时记录 disabled，`system_push=false`。

新增运行模块是 `Apps/MacApp/Runtime/{conversation_store,personal_agent}.py`，原生补丁见 `Vendor/HermesAgent.UPSTREAM.json`。Swift 新文件在现有 SPM target 内自动发现；共享控制 UI 写在现有 `RemoteTaskRecoveryView.swift`，无需新增 Xcode source 条目。版本/生成工程/安装由最终验收阶段处理。

## 本轮证据

- Swift client：复审修复后 45 tests passed，`/tmp/momo-review-fix-swift-final.log`。
- 原生 canonical runner：5 files / 31 tests passed，`/tmp/momo-hermes-regression4.log`。使用独立 frozen test environment，未改用户 runtime 或上游 lock。
- 真实 Hermes + 本地脚本模型 + MCP 屏障：最新复审 `/tmp/momo-review-fix-final-1.log`；模型 acknowledgement 落库早于工具开始、后台工作期间新聊天、两客户端退出后主动结果、两端相同消息 IDs、ticketed steering、pending clarify 阻挡 automation、过期 generation 拒绝均通过。
- 三个真实 crash 窗口：`/tmp/momo-personal-agent-{receipt,admission,started}-2.log`。分别为 receipt 已存、native admission 已存但 product 未绑定、模型续跑 started 后杀进程；最后一种保持 unknown，核对解除不会重试副作用。
- 旧 session：`/tmp/momo-personal-agent-legacy-1.log`、`/tmp/momo-personal-agent-consumed-1.log`。未报告结果被接续；已有真实旧 continuation 的结果不重新激活。
- 真实 Swift journal probe：`/tmp/momo-personal-agent-swift-probe.log`。
- ProductStore / 原生压缩 lineage / notification provider / unknown 禁止新 admission：`/tmp/momo-review-fix-product.log`（4 tests）。Access 新路由和原配对边界另见 `/tmp/momo-access-boundaries-final.log`。
- 合跑 Python discover 时 RTC signaling 出现 401 / 503 差异，旧日志 `/tmp/momo-agent-regression.log`。独立验收确认 dependency-python 已安装 aiortc，按文件独立进程运行全部 MoMo `test_*.py` 均通过（4 个 native RTC probe skipped）；这是跨文件状态污染，不能归因于缺依赖。父验收日志：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/personal-agent-1.30.0/root-runtime-isolated.log`。
- 复审新增：schema 1 首次旧 POST 前 `/adopt=false` 不再误标成功，提交回执保存后重试，未就绪也会下次刷新继续；原 operation/session/draft 不变。
- 复审新增：unknown 只读取原 admission，人工解除后 receipt 与后台卡片变为 cancelled；真实 `/tmp/momo-review-fix-started-1.log` 同时断言仅一个 continuation、未重放副作用。
- 复审新增：失败/停止按共享 run 保留为稳定系统状态行，后续成功消息不覆盖。双端客户端行为回归、20 renderer core tests 与真实 WebKit 均通过；`/tmp/momo-review-fix-renderer-core.log`、`/tmp/momo-review-fix-webkit.log`，截图 `/tmp/momo-review-fix-system-status.png`。WebKit 确认状态没有助手气泡/回复操作，切换外观也保留原节点。
- 复审新增：真实普通后台进程 `terminal(background=true, notify_on_complete=true)` 首次验收暴露上游 stateless API 能力门禁会关闭 notify。现仅给已启用 product 且验证归属的 API 会话绑定原生 async-delivery 能力，HTTP adapter 仍为 non-push；复验 `/tmp/momo-review-process-2.log` 通过，进程完成时无客户端参与，唯一 receipt / 原生 admission / 真实回报，两端补读相同 IDs。新增能力隔离与现有进程通知回归 5 files / 50 tests passed，见 `/tmp/momo-review-fix-native-process.log`。

合成数据均在日志同名前缀的 `/tmp/momo-personal-agent-*` 目录，无真实私人消息；完成后相关 gateway/MCP 进程均结束。

## 可复制复验

在仓库根目录执行；每个 `--data-dir` 必须全新。变量仅供测试命令使用。

```sh
dep_python='/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python'
swift test --package-path Packages/MoMoAgentAgentClient
swift build --package-path Packages/MoMoAgentAgentClient --product momo-agent-probe
node Tests/Support/chat-renderer-core.test.cjs
node Tests/Support/chat-localization.test.cjs
swift Tests/Support/chat-system-status-smoke.swift /tmp/momo-review-system-status.png
uv run --no-project --python "$dep_python" python -m unittest Tests.AgentRuntime.test_personal_agent Tests.AgentRuntime.test_webrtc.RouteTests Tests.AgentRuntime.test_pairing
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-main --steering --controls
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-process --process
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-receipt --fault receipt
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-admission --fault admission
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-started --fault started
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-legacy --legacy unreported
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-consumed --legacy consumed
uv run --no-project --python "$dep_python" python Tests/AgentRuntime/nonblocking_chat_smoke.py --dependency-python "$dep_python" --data-dir /tmp/momo-review-swift --probe Packages/MoMoAgentAgentClient/.build/debug/momo-agent-probe
```

在 `Vendor/HermesAgent` 下执行。验收后会删除临时环境；复验时先用 Hermes 官方 PM 从已固定的 lock 重建：

```sh
uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' -m pm.build_env --source . --out ../../tmp_agent_output/momo-native-review-gateway-env --group dev --group test --extra messaging
```

然后运行 canonical runner：

```sh
HERMES_PYTHON='/Users/syh/Workspace/MoMoAgent-worktrees/hermes-app-20261021/tmp_agent_output/momo-native-review-gateway-env/bin/python' bash scripts/run_tests.sh -j 2 tests/gateway/test_api_authority_controls.py tests/gateway/test_api_authority_retry.py tests/gateway/test_api_pending_daemon.py tests/gateway/test_unknown_automation_settles.py tests/gateway/test_prompt_queued_transfer.py
HERMES_PYTHON='/Users/syh/Workspace/MoMoAgent-worktrees/hermes-app-20261021/tmp_agent_output/momo-native-review-gateway-env/bin/python' bash scripts/run_tests.sh -j 2 tests/gateway/test_api_product_async_delivery.py tests/gateway/test_async_delivery_capability.py tests/gateway/test_background_process_notifications.py
```

## 真实边界

- `independent_chat_while_waiting=false`：Hermes 的确认/澄清等待仍持有 owner claim。新消息可靠接收并排队，处理卡片后恢复；没有另造并发 sibling 或把输入框可用说成独立问题已回答。
- `system_push=false`：离线时结果由 Mac 生成保存，手机重开补读；没有部署 APNs 或声称锁屏推送成功。已读 API 已具备，UI 尚未把 viewport 的确切阅读位置上报。
- delegation 卡片显示原生工作与报告状态；已有 run 的 Stop 保留 Hermes 原生语义，未新增脱离父 turn 后逐个 delegation 的取消协议。未知副作用只允许核对，不做重放。
- 真实 completion 端到端分别覆盖 async delegation 和普通 terminal 后台进程。后台任务卡片目前投射 delegation 状态；普通进程由 Hermes 管理，结束回复已验证，尚未增加同样的过程卡片。
- 控制、模型错误在客户端如实呈现；没有证明模型每次都能正确判断用户完整目标已达成。`reported` 表示已有真实助手回报，不等同外部业务目标经过形式化验证。
- 历史和 run 都有分页；当前客户端完整补读并缓存。大规模历史的增量 run 变更订阅和 projection 查询成本仍可优化，不影响本版离线续跑归属。


## 独立验收与 Beta 1.30.0 交付

执行顺序为：架构 agent 完成源码映射并交接，实施 agent 根据合同改造，主 agent 独立审阅、复验、构建和实装。复审发现并返修了旧 session 采用时序、unknown 解除后卡片不消失、失败状态被后续回复覆盖、普通后台进程不触发完成回报，以及启动连接恢复后错误仍残留五处问题。

最终验收证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/personal-agent-1.30.0/`，机器可读摘要为 `validation.json`。

- 独立 Swift 回归：49 passed；renderer core：20 passed，多语言与真实 WebKit smoke 通过。
- 原生 canonical runner：初轮 31 passed，新增进程兼容组 50 passed（两个组有重叠，不相加当成不同测试）。MoMo Python 全部测试按文件独立进程运行通过；4 个 native RTC probe skipped。
- 独立全新合成 runtime：`root-final-main.log`、`root-final-process.log`、`root-final-{receipt,admission,started}.log`、`root-final-legacy-{unreported,consumed}.log`、`root-final-recovery-probe.log` 全部通过。使用真实 Hermes、工具进程和 SQLite，模型为本地脚本服务，不代表外部模型账户可用。
- Mac / iPhone Beta 最终构建通过，手机安装包 29 项审计和两端签名校验通过。版本统一 1.30.0；修改只在 `codex/hermes-app-20261021`。
- `/Applications/MoMoAgent Beta.app` 已替换并实装检查。原历史和配对保留，Agent 在线、Tailscale connected、1 个已批准设备；重启期间的连接错误在恢复后自行清除，已停止的测试请求仍显示对应状态。
- 物理 iPhone 当前 unavailable，未安装本轮手机 Beta。最终产物在证据目录 `iphone-final/MoMoAgent.app`，bundle ID 为 `com.momoagent.ios.beta`；未安装或修改正式手机应用。
- 真实 Codex 账号验收：已向实际 Mac Beta 发送不读取私人资料的合成后台任务请求。日志记录 `Codex stream produced no parsed stream event within TTFB cutoff (120s)`，模型未输出首包；通过 UI 停止后原生 admission 为 terminal/interrupted。此场景不记通过，也未修改模型账号或网络设置。

APNs、物理手机长时间后台/异网恢复和真实模型完成回报仍未通过实机验收。数据快照保存在私有恢复目录，测试与构建缓存在交付后清理，运行环境和用户资料保留。
