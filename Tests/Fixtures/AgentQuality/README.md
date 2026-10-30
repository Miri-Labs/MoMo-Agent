# D3 固定输入与事实表

2026-10-15：用户已取消计划功能。本目录冻结的 JSON 语料与 hash 保留历史含义，不能直接用其计划写入要求验收当前版本；当前回答型开发集位于 Tests/iPhoneIntegrationTests/LiveAgentQualityFixtures.swift。

这里保存新增 32 个合成任务：16 个 development、16 个 holdout。加上原有 Swift 文件中的 8 个 development 任务，总目录为 40 个，按完整背景 / 缺失歧义 / 指令与版本边界分层为 20 / 10 / 10。

**当前只完成输入和离线验证。新增 32 个尚未接入宿主测试或运行器，没有执行 Archive 准备，也没有调用真实模型。** 默认质量运行器仍只运行原来的 8 个案例。设计与逐项覆盖见 [设计文档](../../../docs/implementation/agent-quality-corpus-design.md)。

## 冻结身份

- `development.json`：新增 16 个开发样本；原有八个输入及其事实表保持原文件与原 hash。
- `holdout.json`：16 个未运行的固定保留样本，包含输入、事实表、预期真实状态和工具授权。
- `manifest.json`：两个文件的字节 hash、canonical hash、逐 case hash、原八个 fixture hash 及分层计数。
- corpus SHA-256：`bd1542fe2a84ae412a6c4f288af94b00f757f5b702733eacd7d817b9aff9f3a8`
- holdout 文件 SHA-256：`09576d05d9f701735c43d2a5be74d1204ca7db722006fb572f0562d1c7be6d5b`

canonical JSON 使用 UTF-8、排序键、无 ASCII 转义、无额外分隔空格。没有忽略任何事实表字段。manifest 的 `corpusSHA256` 绑定 `files`、`legacyCases`、`caseHashes` 三项，避免自引用。原八项 hash 来自已保存的运行证据；离线校验器不解析 Swift，不宣称重新计算过那八个运行时对象，接线时仍需逐一比对。

holdout 的输入与预期在任何模型回答出现前冻结。提示词只能根据 development 调整。若查看 holdout 回答后再据此改提示词，必须记录揭盲和污染，不能继续把相同保留集的结果称作盲测。当前两个新文件都没有模型答案。

## 字段与准备契约

`recordings` 是准备真实档案的声明，`request.prompt` 是唯一用户请求。每份 recording 对应一个独立 session / writer；同一 recording 的 `chunks` 对应同一 epoch 连续帧范围。chunk key 是语料身份，不是伪造的 UUID。准备器必须保存生产返回的真实 UUID、版本、generation、frame 和内容 hash，再将它们绑定到这些 key。

chunk 状态必须使用正式 Archive API 准备：

- `ready`：真实 PCM 收件，claim 后提交明示为 fixture 的合成正文。
- `pending`：仅收件，不产生正文或来源引用。
- `failed`：真实 claim 后 `failAnalysis(retryable: false)`。
- `noSpeech`：正常关闭 epoch，提交完整显式 noSpeech 分析覆盖，无正文。是合成分析状态，不是已运行真实 VAD 的结论。
- `completedWithoutText`：提交空 spans；不能用它冒充 noSpeech。

`mutation.type=revise` 在请求前调用正式 `reviseTranscript`，保持真实 span/frame 身份，并采用 `replacementTexts` 作为当前正文；初始文本只在准备和复核中保留。`delete` 通过正式删除及清理入口生效；已删除正文不进入模型资料。

`archiveExpectations` 是 API 前的检查标准，不是用于写数据库的状态补丁。离线校验只检查声明一致；宿主接线后必须读取真正的 Archive 状态和生产上下文，不准检查器直接造 SQLite、来源或工具结果。纯 pending 录音不能被通用 `addTranscript` 的自动 claim 意外取走；准备顺序和 chunkID 必须明确核对。

`timezoneOffsetSeconds` 总是一个真实合法的 Manifest 偏移。H-M04 使用在上海录制、转述“外地当地下午”的文字：活动所在地仍未知；不能构造系统不支持的空偏移，也不能将录制地当活动发生地。

## 模型输入与复核资料必须分开

仅允许向生产 Archive 写入准备后仍有效的 `ready` 正文；用户输入来自 `request.prompt`。选定来源必须使用正式产生的当前引用。所有段落保留合成 fixture 标记。

以下字段只用于测试和人工复核，**不能拼到用户消息、系统提示或近期生活资料中**：`facts`、`reviewOnlyHiddenFacts`、`archiveExpectations`、`purpose`、禁止字面值、预期工具、预期计划数量和所有 hash。负对照中隐藏的配送 / 预约 / 库存事实只能由复核者看到。

事实表逐项有稳定 ID：

- `required`：必须准确表达的内容；`evidenceKeys` 指可用正文，`kind` 标记 confirmed、unconfirmed、calculated 或 process。
- `forbidden`：禁止的含义；`literals` 仅对明确禁止复述的实体做辅助匹配。
- `clarify`：确有缺口时要澄清的问题和原因，不要求固定问句。

process 项包括确定性准备检查。若生产工具没有向模型暴露某内部状态，不要求模型猜出该枚举或错误代码；仅要求基于可见状态解释缺口、不要捏造。回答与保存计划分别审阅，引用可解析也不能替代语义支持检查。

每例只发一个正式逻辑请求，保留现有 12 次 admission、单次 2,048 输出 tokens、120 秒总期限。分页样本正文约 5.3 KB，按正式工具每页 1,200 UTF-8 bytes 需约五次读取，预留搜索、保存和最终回答，不靠扩预算通过。实际调用数仍以运行证据为准。

## 离线校验

从仓库根运行：

```sh
uv run python Tests/Support/verify-agent-quality-corpus.py
uv run python Tests/Support/test-verify-agent-quality-corpus.py
```

校验器只读输入，不提供重算冻结 hash 的修复开关。17 个正负自检在独立临时目录验证篡改、隐藏事实泄漏、不可用来源、部分转写顺序、空文字/无语音区别、时区、分页与生产预算、配对身份及错误执行声明。自检不会修改这里的文件，也不调用模型或 Archive。

后续还需独立完成：Swift 解码与真实 Archive 准备测试、默认旧八项兼容、清理与预算边界回归、holdout 显式选择和 hash 校验、Release 排除这些资源、development 调整后冻结构建、各 split 三次真实独立运行及逐项人工复核。
