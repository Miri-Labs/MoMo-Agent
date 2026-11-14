# 按任务检索记忆、录音和聊天

此前录音与 Dream 历史查询依赖完整字符串匹配，主 Agent 的活页目录最多展示 80 项。多词查询、不同表达和目录之外的旧笔记容易遗漏。现在主控 CLI、Worker 与 Dream 共用 `memory_search.py`：全部 Markdown 活页、核心记忆、当前录音片段和有效聊天进入可重建的本地全文索引，按相关性返回带来源及版本的原文片段。

## 参考与取舍

参考 EverOS `489ac7e921a81cf82cc9273674a0fa2429b861eb` 的两个实现：

- [agentic.py](https://github.com/EverMind-AI/EverOS/blob/489ac7e921a81cf82cc9273674a0fa2429b861eb/src/everos/memory/search/agentic.py)：细粒度召回后关联原始内容、限制候选量、按名次融合。
- [llm_multiround.py](https://github.com/EverMind-AI/EverOS/blob/489ac7e921a81cf82cc9273674a0fa2429b861eb/src/everos/memory/search/llm_multiround.py)：按问题的缺失方面扩展查询，保留不同子查询的独有证据，核对证据后决定是否继续查找。

MoMo 独立实现 SQLite FTS5 BM25、中文双字切分、英文词干匹配和多查询 RRF（k=40）。每个查询先选每篇原文的最佳片段，再取最多 50 篇候选，防止一篇长文占满候选池；最终优先保留各查询的首项，再按融合分数补齐。查询最多包含原问法与 3 个变体，结果最多 30 项，每项约 1200 字符。

查询改写、证据充分性判断和后续补查由现有 Agent 执行。当前没有文本 embedding 服务，也没有增加向量模型或嵌套模型调用；这是全文检索加 Agent 查询扩展，不能描述成向量语义检索。若原文与全部查询没有共同词项，仍会漏召回。

## 接入与数据边界

- `search_memory(query, alternative_queries?, kind?, limit?)` 搜索 `note`、`recording`、`chat` 或全部来源；目录预览不再被描述成完整索引。
- `read_memory_evidence(id, revision, offset?, limit?)` 分页读取完整来源，返回 `total_characters`、`truncated` 和 `next_offset`。修改、移动、删除或说话人纠正后，旧版本不能继续当作当前证据读取。
- 搜索结果同时包含来源标识、原文位置、内容版本、匹配查询和阅读工具参数。笔记、转写、用户原话、助手回复具有不同的 `basis`；笔记和助手回复不能算作原始来源的独立确认。录音阅读位置以当前片段为单位，完整录音仍通过 `read_recording` 阅读。
- 原 `search_recordings`、非空 `session_search` 和 CLI `search` 共用新索引。CLI `search` 保留原来的录音 `revision` 字段，另外返回 `evidence_revision` 和明确的 `read.arguments`。
- 主控也可执行 `momo-cli search-memory "问题" --alternative-query "检索词"` 和 `momo-cli read-memory-evidence "id" --revision "revision"`。

索引位于 `<data>/runtime/memory-search.sqlite`，权限为 0600。Markdown 与原始资料仍是真源，索引可删除重建。每次查询检查笔记文件签名、录音版本/说话人修正/排除规则及有效聊天内容，只重建变化的条目并删除失效项。隐藏文件、指向记忆库外的文件软链、未生效的补充消息和 Agent 自己推送的简报不进入召回。录音同步尚未收到时无法提前反映手机上的新改动。

索引更新及检索使用同一个短期进程间文件锁；录音的一致性快照在索引写入前释放，聊天读取也先物化并关闭连接。没有持有这些资源等待模型或网络。HTTP 工具通过线程调用索引，避免阻塞 gateway 事件循环。

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
