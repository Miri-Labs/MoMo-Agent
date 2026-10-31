# 可插拔 Agent Runtime 与 DeepSeek SuperAgent 主动引擎接入（2026-10-31）

为实现 DeepSeek 开源 `dsh-superagent-prototype` 的 Day-0 支持，本次将 MoMo Agent 的 Mac 端智能体运行时改造为可互换的双引擎架构（`Hermes Agent` ↔ `DeepSeek SuperAgent`），并在共享个人上下文与记忆底座上跑通了基于同步录音的主动（Proactive）分析、静默准备与成果交付闭环。

## 架构与模块边界

1. **固定上游源码与个人助手适配（`Vendor/SuperAgent/`、`Vendor/SuperAgent.UPSTREAM.json`）**
   - 固定引入 `https://github.com/deepseek-ai/dsh-superagent-prototype`（`6337fc823ce20251c8de8085948165c81aaa701e`，MIT 许可证），运行于 `@deepseek-ai/dsh@0.2.1-rc.5`。
   - `src/app/setup.ts`：当 `sources.github.enabled === false` 时跳过强制 GitHub 仓库探针，允许以纯本地 Personal Agent 模式就绪，并跟踪 `sources.github.enabled` 触发热重载。
   - `src/sources/momo.ts`：新增 `dsh-superagent-momo` Cordis 插件，基于本机回环长轮询桥接 `chat`、`transcripts`、`life_signals` 三类信号流，支持按线程拉取上下文窗口、幂等回传 `acknowledgement`/`reply`，并向 Worker 注入 `$DSH_SUPERAGENT_MOMO_CLI` 与 `$DSH_SUPERAGENT_MOMO_SOURCE_ID`。

2. **双引擎切换与共享数据底座（`Apps/MacApp/Runtime/`、`Apps/MacApp/Context/`、`Apps/MacApp/Access/`）**
   - `runtime_engine.py` 与 `momo_agent.py`：以 `0600` 权限持久化 `<data>/runtime/engine.json`（默认 `hermes`），支持 `momo_agent.py engine --set hermes|superagent` 及进程平滑启停切换。
   - 切换引擎不拆分任何用户数据：会话与 Dots 三态回执继续读写 `<data>/runtime/conversation.sqlite`（`ProductStore`），录音与手机上下文继续读写 `<data>/context/context.sqlite`（`ContextStore`），长期记忆继续共用 `<data>/hermes/memories/MEMORY.md` 与 `USER.md`（`HermesMemory`，由 `momo_cli.py` 提供统一 CLI 访问）。
   - `context_server.py`：在 `superagent` 激活期间自动让渡 Hermes 后台转录归档轮询，由 `SuperAgentGateway` 的增量录音水位线（首次启动建立历史基线，避免重放旧档案）接管新到达或新扩充的同步录音。
   - `rtc_transport.py`：WebRTC 白名单放行 `/momo/v1/proactive` 与 `/momo/v1/proactive/ingest`，同时继续隔离 `/momo/internal/superagent/*` 内部桥接端点。

3. **同步录音主动（Proactive）提示词与策略调优（`superagent_runtime.py`、`superagent_gateway.py`）**
   - 无需单独暴露“主动模式”开关：切换至 `DeepSeek SuperAgent` 后自动启用 `eval.mode = "auto"`，并将 MoMo 当前配置的模型与凭据桥接至 `dsh-llm-pi-ai` 及 `eval.model` / `executor.model` 角色模型。
   - `DEFAULT_PROACTIVE_RULES` 与 `MOMO_PROMPT_CONFIG` 针对自然人际对话/独白录音（说话人未呼叫 AI）重写了 `Orchestrator`、`Admission`、`Worker`、`Work` 与 `Replies` 提示词：
     - **日常闲聊静默忽略**：饮食、天气、寒暄或无明确交付目标的泛谈在候选卡阶段直接 `decision='ignore'`，不向会话产生任何打扰。
     - **高价值事项静默准备、一次交付**：识别会议承诺、行前/评审准备清单、历史上下文核查及明确表达的长期偏好，省略中间回执，在独立 Worker 目录中通过 `$DSH_SUPERAGENT_MOMO_CLI` 核对完整转写、检索上下文、写入共享记忆，再按用户偏好一次性交付结构化 Markdown 结果；严禁编造本地不存在的历史数值，也不向外部第三方自动外发不可逆消息。

4. **Mac 桌面设置界面（`DesktopModel.swift`、`DesktopViews.swift`）**
   - 在「设置 → 通用 → 智能体引擎」提供单一清晰的 `Agent Runtime` 选择器（`Hermes Agent` / `DeepSeek SuperAgent`），不增加额外模式开关；激活 `DeepSeek SuperAgent` 时只读展示就绪状态、进行中工单数与累计评估决策数。

## 验证记录

- **Vendor/SuperAgent 构建与单测**：`pnpm build` 产出 `Vendor/SuperAgent/lib/index.js`；`npx vitest run tests/momo-source.spec.ts tests/bundle-patch.spec.ts` 5/5 通过。
- **Python 运行时测试套件**：运行 `Tests/AgentRuntime/test_*.py` 全量测试通过（含 `test_superagent_runtime.py` 的引擎配置切换、WebRTC 路由白名单、`momo-cli` 跨引擎共享记忆读写、显式对话回执推进与主动录音交付）。
- **Mac 客户端编译**：`xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgentMac -configuration Debug build CODE_SIGNING_ALLOWED=NO` 编译通过（`** BUILD SUCCEEDED **`）。
- **真机模型端到端（E2E）主动与对话验证**（模型：`openai-codex` / `gpt-6.1-sol`，真实启动 `ContextService` + `SuperAgentGateway` + `dsh`）：
  1. **闲聊录音同步**（「午间闲聊」面馆与天气）：Orchestrator 自动判定 `kind=ignore`（`strength=inferred`），会话新增消息数为 `0`。
  2. **未呼叫 AI 的自然会议录音同步**（「周四产品设计同步讨论」，提及明早十点评审三项准备与三段式纪要偏好）：Orchestrator 自主判定 `decision=accept` 并派发独立 Worker；Worker 调用 `$DSH_SUPERAGENT_MOMO_CLI` 读取录音全文与历史上下文，将用户三段式偏好写入共享 `HermesMemory`，并严格按「结论 / 行动项 / 风险」三段式主动向会话交付准备清单，同时诚实标注未查到的历史参数待核对、不伪造数据。
  3. **显式用户提问**（「明天设计评审会是几点？简要回答一句话即可。」）：经 `explicit` 路由完成回复（「按录音中的约定，明天设计评审会是上午十点。」），运行状态正常收敛为 `completed`。
