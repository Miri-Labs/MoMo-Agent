# 按任务检索记忆、录音和聊天

此前录音与 Dream 历史查询依赖完整字符串匹配，主 Agent 的活页目录最多展示 80 项。多词查询、不同表达和目录之外的旧笔记容易遗漏。现在主控 CLI、Worker 与 Dream 共用 `memory_search.py`：全部 Markdown 活页、核心记忆、当前录音片段和有效聊天进入可重建的本地全文索引，按相关性返回带来源及版本的原文片段。

## 参考与取舍

参考 EverOS `489ac7e921a81cf82cc9273674a0fa2429b861eb` 的两个实现：

- [agentic.py](https://github.com/EverMind-AI/EverOS/blob/489ac7e921a81cf82cc9273674a0fa2429b861eb/src/everos/memory/search/agentic.py)：细粒度召回后关联原始内容、限制候选量、按名次融合。
- [llm_multiround.py](https://github.com/EverMind-AI/EverOS/blob/489ac7e921a81cf82cc9273674a0fa2429b861eb/src/everos/memory/search/llm_multiround.py)：按问题的缺失方面扩展查询，保留不同子查询的独有证据，核对证据后决定是否继续查找。

MoMo 独立实现 SQLite FTS5 BM25、中文双字切分、英文词干匹配和多查询 RRF（k=40）。每个查询先选每篇原文的最佳片段，再取最多 50 篇候选，防止一篇长文占满候选池；最终优先保留各查询的首项，再按融合分数补齐。查询最多包含原问法与 3 个变体，结果最多 50 项，每项约 1200 字符。

查询改写、证据充分性判断和后续补查由现有 Agent 执行。当前没有文本 embedding 服务，也没有增加向量模型或嵌套模型调用；这是全文检索加 Agent 查询扩展，不能描述成向量语义检索。若原文与全部查询没有共同词项，仍会漏召回。

## 接入与数据边界

- `search_memory(query, alternative_queries?, kind?, limit?)` 搜索 `note`、`recording`、`chat` 或全部来源；目录预览不再被描述成完整索引。
- `read_memory_evidence(id, revision, offset?, limit?)` 分页读取完整来源，返回 `total_characters`、`truncated` 和 `next_offset`。修改、移动、删除或说话人纠正后，旧版本不能继续当作当前证据读取。
- 搜索结果同时包含来源标识、原文位置、内容版本、匹配查询和阅读工具参数。笔记、转写、用户原话、助手回复具有不同的 `basis`；笔记和助手回复不能算作原始来源的独立确认。录音阅读位置以当前片段为单位，完整录音仍通过 `read_recording` 阅读。
- 原 `search_recordings`、非空 `session_search` 和 CLI `search` 共用新索引。CLI `search` 保留原来的录音 `revision` 字段，另外返回 `evidence_revision` 和明确的 `read.arguments`。
- 主控也可执行 `momo-cli search-memory "问题" --alternative-query "检索词"` 和 `momo-cli read-memory-evidence "id" --revision "revision"`。

索引位于 `<data>/runtime/memory-search.sqlite`，权限为 0600。Markdown 与原始资料仍是真源，索引可删除重建。每次查询检查笔记文件签名、录音版本/说话人修正/排除规则及有效聊天内容，只重建变化的条目并删除失效项。隐藏文件、指向记忆库外的文件软链、未生效的补充消息和 Agent 自己推送的简报不进入召回。录音同步尚未收到时无法提前反映手机上的新改动。

索引更新及检索使用同一个短期进程间文件锁；录音的一致性快照在索引写入前释放，聊天读取也先物化并关闭连接。没有持有这些资源等待模型或网络。HTTP 工具通过线程调用索引，避免阻塞 gateway 事件循环。

并发验证发现，Dream 移动活页时检索可能在文件检查与读取之间遇到 `FileNotFoundError`。现在收集笔记快照时复用 `.notebooks.lock`，释放笔记锁后才写全文索引；外部编辑器在读取前删除的文件会从缓存移除。新增并发移动及检查后删除两项回归。

这次只建立了检索结果到当前原始内容的引用与版本检查，没有实现记忆历史版本、`deprecated_by` 替代链或派生笔记的自动依赖更新。

## 验证

`Tests/AgentRuntime/test_memory_search.py` 覆盖中文多词召回、80 条目录之外的深层活页、长文尾部与全量续读、多方面查询、单篇长文不挤占候选、外部修改/移动/删除/重建、说话人纠正与排除、聊天生效条件、来源归属、并发刷新、Dream/Worker/CLI 一致性。

`Tests/AgentRuntime/memory_search_eval.py` 提供 8 个问题、108 份合成资料的 Hit@3 小型回归；两种检索器使用相同语料和查询。它不评估回答正确率，也不是公开 benchmark：

- 人工提供含准确词项的查询变体：旧字符串匹配与新检索均命中 8/8。
- `gpt-6.1-sol` 在看不到语料时生成查询变体的单轮试验：字符串匹配命中 0/8，新检索命中 7/8；饮食偏好样例因词项不重叠未命中。这组结果只验证这批查询下的差异，不代表生产准确率。
- 2001 篇合成 Markdown（每篇约 60 行）的本机试验：首次建索引约 0.98 秒，5 次复用索引的查询约 0.086–0.099 秒。性能随资料规模和命中量变化。

真实模型扩展测试只从指定 profile 读取模型配置，检索数据与临时索引全部创建在隔离临时目录，不读写用户记忆。运行：

```sh
uv run --python <runtime-python> python -m unittest discover -s Tests/AgentRuntime -p 'test_memory_search.py'
uv run --python <runtime-python> python Tests/AgentRuntime/memory_search_eval.py
uv run --python <runtime-python> python Tests/AgentRuntime/memory_search_eval.py --live-config <agent-data>
```

## 真实模型问答对照（2026-11-15）

`memory_search_agent_eval.py` 让 `gpt-6.1-sol` 自行检索、换词补查、调用生产 Dream 的 `read_memory_evidence` 工具，再生成带来源的答案。使用相同模型、提示词、工具定义和运行预算，每个条件各跑 12 道题、重复两轮。资料为完全隔离的合成笔记、录音、聊天及 100 份无关笔记，不向模型提供预期答案或正确检索词，不读取用户记忆。

这是检索后端的控制实验：LIKE 对照也获得了跨来源搜索、多个查询变体和版本化全文读取，比旧实现具备的工具条件更宽松；它不是两版完整 App 的盲测。正确性要求答案包含题目所需事实、引用目标来源且实际读过该来源，并正确处理证据不足。自动检查事实词项与工具轨迹后，逐条对照原文核验全部最终答案。

| 指标 | 完整字符串 LIKE 对照 | 新检索 |
| --- | ---: | ---: |
| 第一轮有据答对 | 9/12 | 12/12 |
| 第二轮有据答对 | 10/12 | 12/12 |
| 合计 | 19/24 | 24/24 |
| 检索调用总数 | 51 | 32 |
| 全文读取调用总数 | 19 | 24 |
| 单题耗时中位数 | 15.01 秒 | 12.54 秒 |

旧对照两轮都遗漏了饮食禁忌和双端发布状态，第一轮还遗漏了合同可用性指标；新检索均找回。跨来源综合、长文尾部、出差目的地变更均正确。两种方案在“仅有助手猜测”和“资料不存在”两类题上都明确表示依据不足，没有编造确定答案。

保留了[全部答案、检索词和阅读轨迹](memory-retrieval-eval-20261115.json)。第一轮评分曾多要求目的地题未询问的出发日期，已对两个条件同时修正，只重算分数，没有更改答案或删掉失败题。第一轮运行于并发修复前，第二轮运行于修复后；召回与排序逻辑没有因此改变。

这 12 道合成题只支持“本次回归中召回和有据回答更好”，不能外推为生产环境 100% 准确率。仍不保证零词项重叠的语义召回；模型及网络耗时存在波动。没有验证手机真实交互、实际整夜 Dream 效果，也未安装新 App。

额外压力验证：约 2,100 篇笔记、10,000 条聊天及录音，多查询广泛命中时首次索引约 1.75 秒，后续 5 次检索为 0.183–0.194 秒。并发移动复现修复前 100 次检索有 3 次文件不存在异常；修复后并发移动与外部删除回归通过。相关 Python 测试 78 项、TypeScript 测试 11 项和 TypeScript 类型检查全部通过。

复跑真实问答（输出只包含合成资料的答案与工具轨迹）：

```sh
uv run --python <runtime-python> python Tests/AgentRuntime/memory_search_agent_eval.py \
  --live-config <agent-data> --repeat 2 --output /tmp/momo-answer-eval.json
```

## 合并后复核与补修（2026-11-15）

复核 PR #73 后补充了以下真实失败用例，并修复对应路径：

- 手机在正文版本不变时补充或修改 `is_owner`，旧索引会跳过刷新。现在同版本元数据同步推进源更新时间，索引签名包含该字段；同一时钟刻度或时钟回退也能触发刷新，旧证据版本会失效。
- 长转录只命中后部时，开头的说话人标签没有进入命中片段，CLI/Worker 因而将其识别为未知。现在 Context 与 Runtime 共用 `transcript_speakers.py`，在切片前从完整原文解析归属。
- 排除被 Dream 纠正后的说话人时，原始错误标签可能重新出现。现在排除对当前纠正标签同样生效，并保留明确的“归属已排除”标记，避免正文中的方括号再次被当成人名。无空格标签也按同一规则处理。
- 旧 CLI `search --limit 50` 被新上限 30 拒绝，原来的 `title` 与 `seq` 也丢失。现在恢复 50 项和两项元数据，保留原有 CLI 越界截取规则，Python/Worker 工具上限统一为 50；`revision` 仍指原录音版本，`evidence_revision` 用于证据读取。

另补旧索引自动刷新、聊天修改和删除的验证。共 116 项 Python 测试（包括 18 项检索测试）、11 项 TypeScript 测试、类型检查及 SuperAgent bundle 构建通过。固定词项召回回归为 8/8；本轮没有重跑前述 24 次真实模型问答，也不将旧结果当作新一轮结果。

使用正式 `copy_sources` 打包步骤将源码复制到临时独立目录，并在 `/tmp` 以 Python 隔离模式启动，验证新模块来自打包目录、检索及完整原文读取可用。该项验证不包含签名 App 构建、安装和设备交互。
