# Hermes 的记忆编辑链路核对

2026-10-17，按用户要求，在合并前重新核对真正给模型看的提示词、工具声明和 Dream 调用链。Hermes 本体固定到 `868b9f244f5aa3ad238e494048046fe4f29c28ba`；Dream 社区插件固定到 `cbb7f6dd21e9ba828790e38399671807aee1e593`。

## 核对结果

| 源码 | 实际职责 |
| --- | --- |
| `agent/prompt_builder.py:build_memory_guidance` | 自然语言说明哪些长期事实值得记住、如何控制容量；不要求生成某个 JSON 报告 |
| `agent/system_prompt.py:_tool_guidance_block/_memory_parts` | 加入记忆指引和冻结的 Markdown 内容；正文作为上下文读取 |
| `tools/memory_tool.py:MEMORY_SCHEMA` | 模型通过工具调用传入 `action`、`target`、`content`、`old_text`，多次编辑用 `operations`；参数是 JSON，正文是字符串 |
| `tools/memory_tool.py:_memory_tool` | 调用 `add / patch / remove`，返回结构化成功或失败回执；当前不向模型提供 `replace`，旧记录重放仍保留兼容 |
| `tools/memory_tool_store.py` | 用 `§` 分隔条目，匹配旧原文，按最终容量原子写入 `.md`，保留冻结快照 |
| Dream 插件 `skills/dreaming/SKILL.md` | 脚本给 Agent 的 JSON 是候选资料。Agent 读候选后用普通 `memory` 工具编辑，最后给简短文字结果；候选提取与最终记忆写入是两个环节 |

因此，“记忆是 Markdown”与“工具参数是 JSON”同时成立。需要对齐的是 Agent 通过工具编辑正文、收到回执后修正的过程。让助手正文强制输出自定义 `moves / facts / resolutions` JSON，是本分支此前自行增加的协议，不能称为 Hermes 原样流程。

## MoMo 的实现约束

- 后台整理改用真实 `memory` 工具调用；不再解析助手正文中的 JSON 提案。
- 保留 `action / target / content / old_text / operations` 的编辑方式，正文仍是自由 Markdown。跨文件归类使用完整原文的成对移入、移出。
- 个人助理增加不同分类、来源原话与承诺结果检查。这些是 MoMo 的业务扩展，写在工具参数和旁置状态中，不变成正文模板。
- 普通聊天的 memory 工具继续支持用户明确发起的增删改。后台不自行删除或改写旧事实；只有保全原文的移动和有新证据的承诺完成更新。
- 整理任务把一批调用先暂存并核对，结束后统一提交。手机上只在校验失败时允许一次模型修正，不为成功的写入再多跑一轮模型；两次调用共用同一个总时间截止点。

来源：[本体提示词](https://github.com/NousResearch/hermes-agent/blob/868b9f244f5aa3ad238e494048046fe4f29c28ba/agent/prompt_builder.py)、[系统提示词装配](https://github.com/NousResearch/hermes-agent/blob/868b9f244f5aa3ad238e494048046fe4f29c28ba/agent/system_prompt.py)、[memory 工具](https://github.com/NousResearch/hermes-agent/blob/868b9f244f5aa3ad238e494048046fe4f29c28ba/tools/memory_tool.py)、[Dream 指令](https://github.com/itpartypattaya/hermes-dreaming/blob/cbb7f6dd21e9ba828790e38399671807aee1e593/skills/dreaming/SKILL.md)。

MoMo 既有聊天快照的 `personal_context` 仍使用 JSON 外层携带版本、预览与转义后的 Markdown，以维持旧请求重试和指令标签隔离；这是已有适配，与 Hermes 直接装配 Markdown 块不同。Dream 的来源资料也通过结构化输入传入。上述输入封装不要求记忆正文成为字段表，也不是要求助手最终输出 JSON。
