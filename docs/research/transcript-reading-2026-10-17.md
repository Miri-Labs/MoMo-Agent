# Agent 原文读取工具调研

日期：2026-10-17。MoMo Agent 基线：`cb813bbc128deb87b2dc0dd652b6b40f738824f7`。

调研阶段按用户补充要求暂停实现，没有提交、推送或合并应用代码；早期草稿未作为已完成修复。用户随后授权优化并推送 main，实施与验证见[读取工具优化记录](../implementation/transcript-reading-20261017.md)。

## 结论

应让 Agent 按任务主动选择读取范围和额度，正常长度的正文尽量一次读完整；超出额度时返回可验证、可无损续读的一页。不能让一段原文固定只能读 1,200 字节，也不能在生成带续读信息的 JSON 后再用通用字符串裁切器破坏它。

Codex 与 Claude Code 都有输出预算，不是无限灌入上下文。值得借鉴的是可调额度、明确范围和显式不完整状态。具体数字要结合 MoMo Agent 的模型配置、已用上下文和累计来源限制确定，不能直接照搬“默认 2,000 行”或只把 1,200 改成另一个常数。

## 一手资料核对

### Codex 当前实现

查阅的 main 固定在 `ce0323f2f2d3b25e82806cd555237da3db4e1897`，避免用后续变化的 main 解释本次观察。

- [`unified_exec.rs`](https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/codex-rs/core/src/tools/handlers/unified_exec.rs)：`exec_command` 接收可选的 `max_output_tokens`。读取文件可以通过命令选定完整文件、行范围或搜索结果，再指定本次输出额度。
- [`unified_exec/mod.rs`](https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/codex-rs/core/src/unified_exec/mod.rs)：默认单次输出预算为 10,000 tokens；另有 1 MiB 的输出收集上限。收集上限和模型可见预算是不同层次。
- [`utils/string/src/truncate.rs`](https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/codex-rs/utils/string/src/truncate.rs)：`approx_token_count` 使用 UTF-8 字节数除以 4 向上取整，`approx_bytes_for_tokens` 乘以 4。这是近似估算，不是精确模型 tokenizer。Agent 接口采用 token 与底层仍有字节保护可以同时成立；中文不能据此保证精确比例。
- [`tools/context.rs`](https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/codex-rs/core/src/tools/context.rs)：模型可见额度取本次请求预算与运行时截断策略中较小者。输出裁切时有明确警告、原始 token 数估计或省略字节数；还为元数据、警告和标记预留序列化空间，防止已处理结果再次被裁。
- [官方配置 schema](https://developers.openai.com/codex/config-schema.json)：`tool_output_token_limit` 控制存入上下文管理器的工具结果预算；MCP 单工具也可设置 `output_token_limit`。只提高调用参数而不检查运行时策略，不保证模型实际看到更多。

重要区别：当前 Codex 已经移除了旧 `read_file` handler，删除提交为 [14c35a1，2026-03-25](https://github.com/openai/codex/commit/14c35a16a8a41cc16c5e36c2c4287b7b2db6e975)。删除前的 [`read_file.rs`](https://github.com/openai/codex/blob/c6ffe9abab04bd3349ecc49fffc0fbf9551826e6/codex-rs/core/src/tools/handlers/read_file.rs) 确实有 `offset`、`limit`、默认 2,000 行和缩进块读取，但也有每行 500 字节的限制。这只能作为历史对比，不能称为当前设计，更不适合照搬到长句录音稿。

### Claude Code / Claude Agent SDK

核对了 Anthropic 正式发布的 `@anthropic-ai/claude-agent-sdk@0.3.302` 的 [`sdk-tools.d.ts`](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.302/sdk-tools.d.ts)，并通过 npm 元数据确认版本、仓库归属及包 integrity。使用公开类型契约描述能力，不把它等同于完整内部实现。

- `FileReadInput`：`file_path` 定位文件，`offset` / `limit` 指定读取行范围。
- `allow_large`：明确需要整份文件或较大范围时，允许超出常规大小限制，但仍受可用上下文约束。
- `FileReadOutput.file`：提供 `content`、`numLines`、`startLine`、`totalLines`。
- `truncatedByTokenCap`：整份文件读取因为 token 上限变成第一页时，有程序可识别的标志；类型注释还特别说明该标志能在输出重建后保留，区别于展示层横幅。

这次没有核实所有 Claude Code 安装版本共同的默认行数、每行长度或固定 token 上限，因此不把网上常见的“2,000 行”“25k tokens”写成当前统一保证。公开契约足以支持的结论是：范围读取、总量信息、明确截断和主动大范围读取均有专门设计。

[Anthropic 的上下文工程说明](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)支持按需加载完整资料与长期保留原始依据，但也强调有限推理上下文。它不意味着原文工具应永久只给很短摘录，也不意味着每次读取全部个人历史。

## MoMo Agent 现状

| 层次 | 基线行为 | 实际影响 |
| --- | --- | --- |
| 自动注入 | `ContextBuilder` 每段至多 1,200 UTF-8 字节，总正文约 10,000 字节，另有段数限制 | 可以作为近期预览；不应被当作完整资料 |
| 搜索 | `searchPassages` 每条至多 1,200 字节 | 搜索命中是摘录，应能方便定位原文补读 |
| 主动读取 | `read_transcript` 默认 10 段，最多 20 段；遇到一段超过 1,200 字节就停在该段中间 | 单个长段每次实际只读约 400 个普通汉字，调大段数也无效 |
| 已有续读 | `nextOffset`、`nextCharacterOffset`、`hasMore`、段级 `truncated` | 已有分页，不能误称完全没有截断标记或无法续读 |
| 外层输出 | Archive 工具统一 `maxBytes: 32_768`、`maxLines: 500`、保留头部 | 裁切作用于序列化后的字符串，可能使整个 JSON 无法解析 |
| 来源登记 | `AgentSessionPolicy.expose` 限制会话累计来源数不超过 128 | 单页支持数百段之前必须处理此约束；历史来源也占额度 |
| 模型上下文 | 新配置默认 `contextWindow: 32_768`，用户可以设置更大窗口 | 大模型真实支持的窗口与项目实际保存配置需要分别核对 |
| 运行策略 | `PiAgentHost` 关闭自动 compaction；每次请求最多 12 次模型准入、120 秒期限 | 很小的分页容易耗尽轮数；很大的结果也不能依赖自动压缩兜底 |

代码依据：`Tools/ArchiveTools.swift`、`Context/ContextBuilder.swift`、`Runtime/AgentSessionPolicy.swift`、`Runtime/PiAgentHost.swift`、`API/AgentModels.swift`，均位于 `Packages/MoMoAgentKit/Sources/MoMoAgent/`。

Pi 本身并非完全静默：安装的 `pi-durable@1.2.0` 会附加 `truncated` diagnostic，说明丢掉的字节数。但这条通用警告不能修复损坏的 JSON，也不能代替正确的原文续读契约。精确问题是：业务层分页与运行时通用裁切没有协同。

## 已做的复现及边界

用合成的、符合基线字段结构的紧凑 JSON，直接调用项目锁定依赖 `@earendil-works/pi-durable@1.2.0` 的 `dist/harness/output.js` 中实际 `boundOutput`；采用生产配置的 32,768 字节、500 行、head 保留策略。包含 citationURL、来源标识、时间与真实基线转写说明。

| 合成输入 | 完整 JSON 字节数 | 保留字节数 | 结果 |
| --- | ---: | ---: | --- |
| 10 段，每段 400 个普通汉字 | 17,294 | 17,294 | JSON 可解析 |
| 20 段，每段 400 个普通汉字 | 33,614 | 32,768 | 丢 846 字节，JSON 无法解析 |
| 20 段，每段含 1,199 个换行加一个字母 | 57,594 | 32,768 | JSON 转义膨胀，丢 24,826 字节，无法解析 |

这证明“每段正文预算相加不超限”不代表完整结果不超限；元数据与 JSON 转义都要计入。合成记录没有经过 Swift JSONEncoder、Archive、真实 ASR 或模型调用，不宣称完整 App 回归通过。

复现脚本与原始结果保存在本次工作区 `/workspace/scratch/read-tool-research/reproduce.mjs` 和 `reproduction.json`。未上传任何用户录音或调用付费模型。

## 建议的修复契约

1. **预览与原文分别定义。** 近期上下文与搜索可以给摘要或摘录；`read_transcript` 应能返回完整长段，不继续套用 1,200 字节的预览上限。保留原文、citationURL 和时间含义。
2. **Agent 可以主动多读。** 提供每次可选的 token 输出预算和段数/范围；默认尽量覆盖正常长度讨论，需要时主动申请更大范围。类似 Claude 的 `allow_large` 或 Codex 的 `max_output_tokens`。第一版曾暴露字节预算；用户指出后已改为 `maxOutputTokens`，字节仅保留作底层传输保护，见[token 修正记录](../implementation/transcript-token-budget-20261017.md)。
3. **同时核算真实上下文和底层额度。** 考虑当前模型配置、系统提示、既有消息、其它工具结果及回答预留，明示生效预算；确认来源登记和运行时输出预算不再形成更低的隐藏上限。避免模型已请求更多而运行时又悄悄裁掉。
4. **返回完整的一页。** 计入 JSON 转义、引文链接、时间、说明和续读字段的实际序列化大小，提前结束这一页；完整 JSON 不再进入一个更小的通用截断器。
5. **明示覆盖范围与结束条件。** 返回总段数或快照边界、本页起点/终点、是否还有内容、未读原因和精确续读位置。段中续读继续使用 Unicode 安全边界，明确 `characterOffset` 的单位。全文/整段完成与页结束必须可区分。
6. **保留来源失效语义。** 读取更多不能破坏修订、删除后的来源验证。持续录音会追加转写，总量与“已读完”要限定到某个快照；不能承诺读完未来内容。不能直接解除来源限制却不评估会话持久化成本。

不建议为了这次修复重新加入一个通用 shell/文件系统工具、把所有历史自动塞入系统提示，或者先做整套记忆架构重构。

## 实施前应验证

- 一段超过 1,200 字节的正文在预算内完整返回；常规多段讨论明显减少工具轮数。
- 长中文、Emoji、组合字符、换行、引号及反斜线，逐页拼接与原文完全相同。
- 最终送达模型的结果仍是完整 JSON；不能只测分页 helper、忽略 Pi 的最后一次裁切。
- 达到字节预算、段数预算、空录音、恰好页尾和最后一页时，结束/续读信息一致；任何续读都必须前进。
- 大于 128 个来源及已有历史来源的会话不因新默认值直接失败；保留撤销、修订与删除验证。
- 小窗口与大窗口配置分别验证有效额度；关闭 compaction 时，不以未实现的自动压缩为依据。
- 只增加与本次行为相关的回归；不需要为扩大额度运行 ASR、UI 或付费模型矩阵。

本工作区是 Linux 且没有 Swift/Xcode。应用及 Pi Swift harness 测试须在具备 Apple SDK 的环境执行；本次调研不把未运行的 Swift 测试计作已通过。
