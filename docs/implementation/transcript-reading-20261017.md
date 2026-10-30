# Agent 原文读取工具优化

日期：2026-10-17。用户授权完成优化并推送 main；基线为 `cb813bbc128deb87b2dc0dd652b6b40f738824f7`。设计依据见[一手资料调研](../research/transcript-reading-2026-10-17.md)。

本文件保留第一版的字节预算与验证历史。用户随后指出 Agent 不应按 KB 选择读取量；当前契约已改为 token 预算，以下旧参数已被替换，见[token 修正记录](transcript-token-budget-20261017.md)。

## 读取契约

- `read_transcript` 不再复用搜索摘录的每段 1,200 字节上限。默认申请 200 段 / 65,536 UTF-8 字节，可提高到 1,000 段 / 262,144 字节；最小页预算 4,096 字节。搜索和自动近期预览继续作为摘录，不自动上传全部历史。
- `maxBytes` 约束完整 JSON，包括来源、citationURL、时间、转义、转写说明和续读信息。正文只在页预算不足时拆分；二分选择能放下的最长 Unicode Character 前缀，续读不丢失组合字符或 Emoji。
- 页级 `truncated` / `hasMore` 表示尚有未读内容；`truncationReason` 为 `byte_limit`、`context_budget` 或 `passage_limit`。段级 `truncated` 只表示该段未读完，和只读了部分段数分别解释。
- 返回起点 `offset` / `characterOffset`、快照 `transcriptVersion`、总段数 `totalPassages`、精确 `nextOffset` / `nextCharacterOffset`、申请额度 `requestedMaxBytes` 和生效额度 `maxBytes`。`characterOffset` 按 Swift Character，即扩展字素簇计数。
- 续读传回 `transcriptVersion`，固定在同一转录快照。录音追加转写不改变该快照的结尾；修订或删除后仍拒绝旧来源。旧调用不传版本时继续读取当前快照。
- Archive 工具的 Pi 最终输出保留额度提高到 256 KiB，原文页在返回前再次检查 JSON 实际大小，避免外层截坏已分页结果。搜索最大 20 条、每条 1,200 字节，计入 JSON 转义和现有固定元数据后也有足够空间。

## 上下文与来源限制

模型配置仍由用户控制，没有替换已保存的窗口大小。每轮准备模型时同步配置；beforeRequest 在隐私过滤后的消息上建立用量估计，afterResponse 优先采用 provider 返回的总用量（含缓存和输出），同轮后续工具结果继续计入。

合并前远端 main 新增了 `dbbe915` 的可见上下文压缩修复，本任务已合入该更新。保留其按当前模型配置的主动压缩、完整回答预算、隐私与取消保护；本次读取预算在压缩后的 beforeRequest 重新计算，不覆盖压缩设置。仅 Actor 的新增私有状态发生文本冲突，合并时保留读取预算与压缩记录的两组状态。共享版本同为 1.3.4 / 21，本次仍未生成新的安装包。

合并后的原生编译发现新压缩钩子调用可抛错的 `lifeTimeline.accessRevision()` 时缺少 `try`；已补齐并保留原钩子的错误处理。此问题由 Xcode 类型检查发现，语法解析不能替代原生编译。合并后的 Pi JS 测试也已重新执行，47/47 通过。

原文预算采用剩余窗口收紧，预留配置的最大回答 tokens，另预留窗口的 1/8（最多 4,096 tokens）给工具 schema 和消息 framing，避免固定大预留使最小支持的窗口无法读取任何页面。缺少 provider 用量时，以序列化消息 UTF-8 字节数作为保守文本 token 估计；新返回的原文也按每字节至多一个 token 留额度。**这不是精确 tokenizer，也不是所有 provider、多模态与协议开销的严格保证。** 它优先避免默认小窗口直接接收 256 KiB 正文；大窗口仍允许申请完整 256 KiB。额度不足最小完整页时，返回明确的 contextBudgetExhausted 工具错误，不能假装读完。

累计来源上限从 128 提高到 4,096，在 Archive 验证和 Agent 会话中使用同一常量；仍限制持久化规模。达到累计上限时返回单独的 sourceBudgetExceeded 错误，明确增大单页不能解除该限制，不与“单字符无法放入页面”混淆。来源去重保留原有次序与身份信息。批量验证按 session / version 复用一次文档解码和段索引，登记按 session 合并 SQLite 更新，避免扩大读取量后每段重复解码整篇文档。所有返回内容仍登记真实来源；修订、删除和会话清理规则保留。

## 验证

新增及调整的回归涵盖：长段一次完整返回；4 / 64 / 256 KiB 页的中文、Emoji、组合字符与 JSON 转义无损重组；段数边界、空快照和明确结束；不可拆的超大单字符；上下文额度收紧与后续工具耗用；真实 Pi harness 下超过 32 KiB、超过 128 个来源的结果实际到达模型，且重启和修订失效仍有效；4,096 个来源边界；追加录音后的版本固定与修订/删除拒绝。

工作区为 Linux，无本地 Swift/Xcode，已添加任务范围内的 Xcode 27 GitHub Actions 入口执行原生测试。未调用付费模型或运行 ASR/UI 矩阵。

基线的广范围原生检查（应用源码仍为 `cb813bb`）已先执行：[run 39017971741](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39017971741)。该次 Archive 的 151 tests / 27 suites 通过，Agent 的 116 tests / 3 suites 有 15 issues，既有失败涉及：

- `realPiToolsParseEquivalentDateRangesAndFollowPageCursors` 的两个参数分支；
- `selectedOldRecordingReachesProductionPiPromptWithoutSearch`；
- `temporalPromptFailureBlocksStalePiSectionAndRetryAfterRestartKeepsRequestClock`。

这些测试仍按旧的自动上下文注入方式断言。本任务不据此扩张修改自动上下文产品行为，也不把它们报告为通过。后续常设 CI 明确聚焦原文读取、来源校验和 Archive；没有把上述广范围失败改成通过或删除原测试。

实现初次广范围检查：[run 39018213010](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39018213010)。Archive 151 tests 继续通过，新增的分页、额度和来源边界通过；Agent 汇总 122 tests / 16 issues，其中 15 项与基线一致，新增大结果测试因夹具误用“修订”新增段落而被来源保护拒绝。已改为通过真实 PCM 收件、分析领取与 commitTranscript 入库构造 300 段正文，再进入真实 Pi harness。

任务范围复跑 [run 39018406945](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39018406945) 成功，151 项 Archive 和 13 项 Agent 测试通过。随后把重组比较从 Swift 字符串相等加强为 **UTF-8 字节完全一致**；[run 39018528610](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39018528610) 在 `37191881808794969dd39f9da5eeaa84414b2a5e` 上再次成功，151 + 13 项通过。此后合入上述 main 更新，并扩大原生检查范围以覆盖其 compaction 回归；合并后的结果另记。

合并 main 后的编译失败保留在 [run 39018708817](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39018708817)，未通过项为上述缺少 `try`。修复后的 [run 39018857544](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39018857544) 通过 151 项 Archive 与 16 项读取、来源、压缩相关 Agent 测试。最终又核对了 4,096 来源边界下行动前的去重，避免选中来源重复计数；最终源码 `e547726faca21cf14a50ea5f35c07cde6722408f` 的 [run 39019054474](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39019054474) **151 + 16 项全部通过**，包含完整聊天保留、重启与重新生成、压缩隐私、原文页实际到达模型和 UTF-8 无损重组。最后的提交仅更新验证记录。

离线 corpus 检查器同步修正了“原文每页最多 1,200 字节”的旧假设，仍要求相关输入超过搜索摘录，并保留固定的模型准入数约束。17 项检查器自检通过，冻结的 32 条新 JSON 场景结构校验通过；未改变冻结内容与哈希，也不代表执行了这些场景的模型质量评估。

代码版本配置为 1.3.4，内部构建号 21。本次交付为代码变更，没有生成或安装 iPhone / Watch 发布包，因此没有把历史安装、发布包检查或真机结果计入本次验证。
