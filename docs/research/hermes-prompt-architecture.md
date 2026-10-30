# Hermes Agent：提示词、人格与记忆

研究日期：2026-10-15；固定上游 `NousResearch/hermes-agent@db44c46208f1b421b4ecb7e56bf9d68b0423906f`，MIT。以下结论核对了源码，而非只照文档示例。默认人格保留上游 SOUL.md 的主要内容，译为中文并调整产品身份，不额外堆叠针对单次模型回复的风格禁令。许可证保留在 [hermes-LICENSE.txt](hermes-LICENSE.txt)。未复制 Python 实现或新增 Hermes 运行时依赖。

| 入口 | 实际职责 |
| --- | --- |
| [`agent/prompt_builder.py:load_soul_md`](https://github.com/NousResearch/hermes-agent/blob/db44c46208f1b421b4ecb7e56bf9d68b0423906f/agent/prompt_builder.py#L1652) | 从固定 profile home 读取 SOUL.md，不从随意的工作目录读取；去空白、扫描、截断；缺失/空/不可读返回 None，让 identity 使用默认值。用户自己编写的 SOUL 扫描命中只警告；第三方分发的 SOUL 可阻断。 |
| [`agent/system_prompt.py`](https://github.com/NousResearch/hermes-agent/blob/db44c46208f1b421b4ecb7e56bf9d68b0423906f/agent/system_prompt.py#L730) | `build_system_prompt_parts` 按 stable、context、volatile 三层组装；人格在最前，工具指导跟随；项目/部署上下文居中；技能索引、记忆、用户资料和运行信息在尾部。`skip_soul` 防止重复注入。 |
| [`tools/memory_tool_store.py`](https://github.com/NousResearch/hermes-agent/blob/db44c46208f1b421b4ecb7e56bf9d68b0423906f/tools/memory_tool_store.py#L175) | MEMORY/USER 是容量有限的持久文件；加载时创建冻结的 prompt snapshot，文件更新不直接修改本轮缓存。文件锁、严格 UTF-8、原子写、精确匹配和漂移检查保护编辑。默认 memory 2200 字符、user 1375 字符。 |
| [`tools/memory_tool.py`](https://github.com/NousResearch/hermes-agent/blob/db44c46208f1b421b4ecb7e56bf9d68b0423906f/tools/memory_tool.py) | 单一 memory 工具按 user/memory 分目标，支持 add/patch/remove 及原子批次，拒绝把任务日志、原始资料倾倒进长期记忆；可经过配置的写入审批。SOUL 不属于 memory 工具的目标。 |
| [`invalidate_system_prompt`](https://github.com/NousResearch/hermes-agent/blob/db44c46208f1b421b4ecb7e56bf9d68b0423906f/agent/system_prompt.py#L808) | 压缩等重建边界清缓存、重读记忆和插件快照。临时 overlay 在 API 调用时注入，不回写长期 prompt。 |

官方 [Prompt Assembly](https://hermes-agent.nousresearch.com/docs/developer-guide/prompt-assembly) 的具体例子仍含旧顺序，应以同版本 `build_system_prompt_parts` 为准。`SOUL.md` 是 durable identity；personality 配置是会话 overlay，二者不是同一份文件。上游的大量 coding/terminal/skills 操作指导不适合 MoMo Agent。

MoMo Agent 的对应设计见 [ADR](../adr/file-backed-assistant-context.md)。本次只借鉴文件分工、确定的装配顺序、冻结快照和独立管理入口：不照搬 Hermes 的角色身份、全局 shell、项目 AGENTS 扫描或自动记忆写入政策。录音原文仍走原有 Archive 的版本/删除屏障，不转存为长期记忆。

## 对齐范围和明确差异

| 机制 | MoMo Agent |
| --- | --- |
| SOUL / USER / MEMORY 独立管理、单次人格注入 | 已接入；默认人格是独立 Markdown 资源，原有产品规则独立于可编辑人格。 |
| 单一 memory 工具、add / patch / remove / 原子 operations | 已接入；支持 new_text 别名、完整条目优先、唯一片段修改、去重、最终预算、失败不部分提交、三次连续失败后停止写入。另提供 read 取得当前条目和版本。 |
| 并发与写入保护 | 同一文件锁、严格 UTF-8、原子写；本应用额外要求版本 token，设置和模型使用同一存储接口。采用精确文本匹配，不做 Hermes 的引号/破折号宽容匹配。 |
| 缓存与刷新 | Hermes 冻结到会话重建；本应用冻结到逻辑请求结束，同一请求的重启重试不刷新，新消息刷新。 |
| 容量 | Hermes 默认按字符计数；本应用按 UTF-8 字节计数，SOUL 8192 / USER 4096 / MEMORY 8192，界面明确显示。超限拒绝，SOUL 留空用默认；不可读或损坏明确报错，不静默回退。 |
| 信任与审批 | Hermes 有威胁模式扫描、第三方 profile 归属和可配置审批。这里未移植该扫描器或审批系统：SOUL 仅用户设置可改，工具只能操作两份资料，内容作为数据注入，写入仅限用户明确要求。关键词扫描不能替代权限边界。 |
| 会话 personality 预设、插件 overlay、技能/项目发现、外部记忆 provider | 本次不提供；不宣称整个 Hermes prompt 子系统已完整搬入。 |

源码与官方文档会继续变化；上述对齐只针对本页固定提交。
