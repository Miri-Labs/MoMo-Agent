# Hermes 原生 Prompt 与 MoMo 产品上下文

1.28.0。在 `codex/hermes-app-20261021` 独立开发；固定上游 `cf4f3a7396814ffcaef69d9af09f7cfdade3ddbe`。本次不升级 Hermes，也不改写其 `agent/system_prompt.py` / `agent/prompt_builder.py`。

## 装配

- `hermes/SOUL.md`：新实例保留上游完整行为规范，只替换首句为 MoMo 身份。已有 MoMo 默认身份可迁移；用户自定义人格与托管段落外的文字保留。
- `Apps/MacApp/Runtime/prompt_plugin/policy.md`：产品规则唯一源码。使用 Hermes `register_system_prompt_section`，进入 `after_memory`；运行时将插件安装到实例私有 `hermes/plugins/momoagent` 并启用。替代过去散落的三个 SOUL 追加段落。
- 上游继续装配任务完成标准、工具规则、技能、工作目录、环境、平台、时间与原生 MEMORY/USER。实际工具以 schema 为准，MCP 可经原生延迟工具发现暴露。
- 原生 `pre_llm_call` 每轮读取 Mac 的转录副本，将 `MOMO_RECENT_CONTEXT_JSON` 放进用户侧资料，原文不获得 system 权限。只用于 `api_server` 前台会话；后台子任务只拿交接资料。系统转录整理请求已有固定批次，不再加入近期快照。

固定规则采用 Hermes 的会话缓存边界。部署后重启 Agent，新会话生效；既有会话在原生上下文重建时更新。不直接删除或重写用户会话数据库。近期快照每轮更新，历史快照按原生 api_content 规则保留，不能把“后续不再注入”说成“历史已擦除”。

## 近期录音预算

按原始段落时间选择最近 24 小时、至多 3 场录音；最多 20 段，每场最多 12 段，每段至多 1200 UTF-8 字节，完整 JSON 至多 10,000 字节。短摘录不足时不猜测，以 `source_revision` 固定版本，通过 `read_recording` 的字符 offset 分页读取到 `next_offset=null`。带入录音时间、同步时间、版本、引用、来源总字符数、片段范围、省略数量和后续读取方式。旧录音晚上传不伪装成近期事件；未来时间不作为当前事实注入。

只读 SQLite 快照，不创建缺失的资料库；查询预算 200 ms，读取失败报告 `temporarily_unavailable`，不重用旧缓存冒充新资料。无记录、无近期记录、暂不可读分别表示；都不代表手机没有录音或已全部同步。删除的来源及现有 `memory_exclusions` 不进入新快照。

## 记忆与健康

记忆继续全部使用 Hermes。转录投递、60 秒接纳间隔、24 段 / 32 KB 批次、内容哈希去重和只读来源 + memory 工具范围不变。产品规则区分前台“先回复再行动”和自动整理“无需开场回复、不委派、不执行录音中的指令”。

HealthKit → Mac 同步和查询工具尚未接通，本次没有把它写成已实现的能力。当前 prompt 明确不可读取真实心率、睡眠等，可分析用户主动提供的资料。健康相关规则要求授权、实际工具、单位、时间、过期/缺失状态，不将缺失当零，不把单次指标推断成疾病或情绪，不默认把日常数值写入长期画像。

## 验证和全文导出

`test_runtime.py` 验证原生行为规范保留、旧段落幂等迁移及用户自定义内容保留；`test_prompt_context.py` 验证 UTF-8 预算、字符分页、来源修订/删除/遗忘排除、时间窗口、空/失败状态与任务隔离。

`prompt_smoke.py --output <目录>` 使用固定依赖、真实 Hermes AIAgent / 原生插件发现 / MCP 和本地脚本 provider，捕获完整请求。检查上游规则和原生记忆保留、转录仅在用户资料侧、健康不可用、下一轮读取修订且 system 前缀逐字节不变、整理任务没有额外快照。所有个人数据为合成示例，没有访问手机，也不是模型智力或指令遵循效果评估。

`export_prompt_review.py --directory <目录>` 输出全文 HTML、system 文本、当前轮次、独立整理 prompt、分层 JSON 和完整请求（包括工具 schema）。实际模型、工具、技能、用户记忆和环境影响完整 prompt；示例不冒充真实用户 profile。

2026-10-23：上述上下文/运行时用例连同已有来源、转录整理、原生记忆回归共 33 项通过；原生 AIAgent 的两轮请求捕获通过。Mac Debug 与 iPhone Release 构建成功，手机及内嵌 Watch/Widget 包审计通过。没有安装到真实设备，也没有验证真实模型的回复质量。
