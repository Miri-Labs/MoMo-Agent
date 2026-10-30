# 2026-10-24 实施记录

基于 `rakazo-interaction-gaps-20261024.md`，保持一个可见 conversation、Hermes 原生执行/记忆和内嵌 Tailscale。无新执行器、数据库服务或客户端后台续跑。

## 已落地

- 默认 `intent=new` 创建受信 native work。每个 work 保留自己的 claim、审批/澄清和 execution session；公共 `session_id` 仍是 `momo-main-*`。审批 A 时的新消息 B 独立执行，不消费 A 的控制卡。
- 首轮继承固定的共享 user/assistant 快照（最多 40 条、24 KiB，系统提示说明边界）；当前请求显式标记，原始可见输入不改写。旧 session/journal 和原 operation 保留。
- `intent=steer` 绑定 work/run/generation；过期或等待输入返回 409。持久 steer-only fence 阻止未消费/重启后的补充变成新 FIFO 任务。客户端可把未送达补充恢复为草稿，保护已有草稿且不自动发送。
- `background_work` 读原生 delegation ledger 和不消费输出的 process 元数据。取消按精确 ID/incarnation/generation，先存请求再中断；确认原生终态才显示停止。失去进程证据显示持久 unknown，不冒充取消成功；取消的原生结果仍经模型回报。
- 电脑 gate 位于原生 guardrails 后、MCP RPC 锁前，绑定 native claim 和现有 lease epoch；等待保留原调用和任务。人接管后旧坐标不会重放，必须重新截图；取消等待后归还不复活。异步 child 继承 gate。
- Swift 模型/Store 增加工作标题、状态、定向补充、持久取消和按钮 in-flight 状态。取消网络重试复用 operation；过期 409 停止重试。正常 UI 由根 agent 负责。
- HTTP 与 RTC 均允许 `POST /momo/v1/conversation/work/{id}/cancel`；请求含 `operation_id`、`execution_generation`。

## 验证

在仓库根执行。每次 smoke 使用新的目录。依赖 Python 只用于解释执行，不修改其包或用户数据。

```sh
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-interactions --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --interactions
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-background --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --background-controls
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-computer --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --computer
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-process --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --process
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-steering --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --steering --controls
uv run --no-project Tests/AgentRuntime/nonblocking_chat_smoke.py --data-dir /tmp/momo-review-fault-started --dependency-python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' --fault started
uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' python Tests/AgentRuntime/test_interaction_work.py
swift test --package-path Packages/MoMoAgentAgentClient --scratch-path /tmp/momo-review-swift
```

`--interactions`、`--background-controls`、`--computer` 可加 `--hold-seconds 120` 保留合成 runtime 用于 UI 验收；正常退出会停止进程。所有 smoke 已通过。电脑场景是**真实 Hermes + 生产 MCP + 合成 Mac IPC**，不等同实际屏幕/鼠标权限验收。

日志：`/tmp/momo-gaps-interaction-2.log`、`/tmp/momo-gaps-background-2.log`、`/tmp/momo-gaps-computer-1.log`、`/tmp/momo-gaps-process-2.log`、`/tmp/momo-gaps-steering-1.log`、`/tmp/momo-gaps-fault-started-1.log`。测试数据同名前缀目录。

Swift 60 项通过；新增交互单测 6 项通过；MoMo Runtime 的全部 16 个 `test_*.py` 以逐文件独立 unittest discover 收集，120 项中 116 passed、4 native RTC probe skipped，日志 `/tmp/momo-gaps-runtime-regressions-final.log`。

原生回归用官方 frozen build_env 创建 `/tmp/momo-gaps-native-testenv`，没有修改用户 runtime 或上游 lock。canonical runner 16 文件：373 passed、21 skipped、1 failed。唯一失败是 `tests/tools/test_delegate.py::TestDelegateTask::test_child_dedicated_db_follows_parents_db_path` 的 macOS `/var/tmp` 与 `/private/var/tmp` 字符串路径断言；该 DB 建立代码没有改动；已在无本轮补丁的 HEAD archive 副本用同一 canonical runner 复现，证据 `/tmp/momo-gaps-native-baseline.log`。日志 `/tmp/momo-gaps-native-regressions.log`，不能宣称原生整组全绿。

```sh
cd Vendor/HermesAgent
HERMES_PYTHON=/tmp/momo-gaps-native-testenv/bin/python scripts/run_tests.sh -j 4 tests/gateway/test_api_product_async_delivery.py tests/gateway/test_session_api.py tests/gateway/test_session_authority.py tests/gateway/test_shared_session_controls.py tests/gateway/test_pending_steer_drain.py tests/gateway/test_session_steer_stale_busy_refusal.py tests/gateway/test_api_run_steer_before_adopt.py tests/gateway/test_async_delegation_session_binding.py tests/tools/test_async_delegation.py tests/tools/test_delegate.py tests/tools/test_delegate_late_child_inherits_stop.py tests/tools/test_delegate_capability_inheritance.py tests/tools/test_process_registry.py tests/tools/test_process_registry_list_exit.py tests/tools/test_process_registry_completion_races.py tests/agent/test_tool_executor_checkpoint_paths.py
```

## 保留边界

- 真实 macOS 屏幕/输入权限尚未开放，未操作真实桌面或手机。实现子 agent 未安装或发布；根 agent 交付结果见下方。
- retained process 消失/重启后无法证明执行结果时保留 unknown，不重放有副作用任务。
- 共享上下文是固定、有界的角色化快照；跨工作长历史由 Hermes 原生 session_search 检索，不承诺无限自动注入。
- APNs 实际部署/凭据仍属于前一轮未部署边界，本轮没有改变其就绪状态。


## 根 agent 独立验收与交付

版本 1.32.0，独立 `codex/hermes-app-20261021` 分支；不合 main。Mac Beta 已替换并启动，最终从实际输入框发送无工具请求，真实模型返回“已就绪”且 run 状态为 completed。旧数据升级后发现并修复旧 root 被 legacy / work 双路径重复展示的问题：投影严格按本产品 inputs / completion admission 归属，原有 legacy 历史只投影一次；真实数据核对后仅清理本轮产生的 6 条重复副本，保留私有备份、原文与游标。

独立重跑 --interactions、--background-controls、--computer、--legacy consumed 均通过；补测了实际 Swift DesktopControlHost 的跨 work / 旧 epoch 拒绝。运行层逐文件 120 项：116 passed、4 skipped；Swift 60 项通过。两端 Beta 完整构建通过，手机、Watch、Widget 的 29 项包身份与版本检查通过；未安装手机。原生 Hermes 回归的 1 项已复现基线失败保留原结论。

真实 Mac SwiftUI（合成服务器状态）点验：等待卡存在时发送普通消息并得到回复；选定任务补充、退出后保留草稿；指定任务取消时仅原按钮内加载；澄清答案仍发往原 run；限高滚动区域不遮挡输入框。真实 WebKit 输入滚动回归通过，聊天 renderer 核心回归通过。合成 UI fixture 最初缺 capabilities 路由导致的 404 留在截图中，仅为 fixture 准备错误，补齐后正常发送通过。

界面检查使用默认字号，沿用现有组件；新增 17 条短文案具备中、英、日、韩四语。新 geometry 的 Sendable 捕获警告已修复。未改自定义动画，不做全系统性能采集。真实手机漫游/后台、APNs 投递、真实屏幕/鼠标验证仍待对应设备和权限，不用本地 fixture 结果替代。

本轮证据在 `outputs/interaction-gaps-1.32.0/validation.json`（方案工作目录）；安装身份 `com.momoagent.mac.beta`，手机构建身份 `com.momoagent.ios.beta`。正式 App 和设计稿未包含在提交中。
