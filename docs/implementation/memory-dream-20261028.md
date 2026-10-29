# MoMo Agent 记忆与 Dream（1.38.0）

## 根因

升级前正式 Mac 1.37.0 的配置已开启 Hermes 原生记忆，转录任务也在执行，但检查时 313 个转录任务标为 done、原生 memories 目录仍为空。旧完成条件只有 run=completed，没有核对 memory 工具写入或明确的无需改动回执。输入又被切成最多 24 个很短的 ASR 片段，模型反复以“归属不清/临时信息”跳过。插件策略确实已加载，并非 prompt 未注入。

产品为每个工作创建独立原生会话，单会话累计轮数不能可靠触发全局整理。旧手机 Pi Dream 没有迁回 Mac；此次保留 Hermes 引擎和存储，只补产品所需的持久触发与回执。

## 当前行为

| 路径 | 触发与输入 | 保存位置 |
| --- | --- | --- |
| 聊天整理 | 对话静默至少 60 秒、没有活跃用户任务；从共享聊天增量读取，跨会话与重启保留 seq/字符偏移；每批最多 48 个部分、32 KB | Hermes USER.md / MEMORY.md |
| 转录整理 | 新增/修订资料持久排队；最多每 60 秒接纳一个批次；最多 96 个连续片段、32 KB，长段按 UTF-8 分页继续 | 同一份 Hermes 原生记忆 |
| Dream | 首次有已处理资料即可空闲复盘；之后至少间隔 6 小时且证据有变化；连续录音不会让到期 Dream 饥饿 | 原生 memory 的合并、纠正、删除操作 |

Dream 对照现有记忆，复盘重复、冲突、已完成与过时信息，必要时用 session_search / 只读录音工具查来源。不新建事实库、图谱或手机侧 Agent。新会话由 Hermes 原生机制读取同一份记忆；不在正在执行的会话中途改 system prefix。

用户明确表达的稳定偏好/关系进入 USER；持续项目、目标、有价值的事件背景进入 MEMORY。未知说话人仍可保留明确的讨论主题，但要注明日期、来源和“归属未确认”，不能变成用户自己的偏好、承诺或疾病。助手回复单独不能证明事实。原始转录不因摘要或记忆容量而丢弃。

整理会话仅开放 memory、session_search 和只读录音 MCP，不执行历史材料里的命令，不操作电脑、不发消息、不改配置或技能；关闭嵌套的原生后台 review，避免重复整理。

## 可靠性与升级

- run 完成后，必须有 updated / no_change 的结构化说明。updated 必须对应同一个真实 Hermes session 的成功 memory 工具回执；最后一次写入失败时不能用 no_change 掩盖。
- 只有校验完成才推进聊天/转录进度。已知终态失败最多自动重试两次；丢失接纳回执继续使用原幂等键，结果未知或接纳保证过期时待核对，不盲目重跑。
- Dream 完成只记录它启动时的输入签名，不把执行中后来到达的资料误判为已处理。没有新输入不会仅因时钟反复调用模型。
- 升级时仅对“原生记忆为空且从未成功写入过”的旧 profile 做一次资料重整理。保留历史任务与原文；有历史成功写入的 profile 不自动回放，避免复活用户删掉的记忆。
- 记忆页显示实际整理状态与上次 Dream 时间；每 15 秒仅在该页面可见时刷新，已有记忆保持显示。

## 验证

- `uv run --python <现有私有 runtime Python> python -m unittest discover -s Tests/AgentRuntime -p <测试文件>`：memory_review / transcript_ingestion / prompt_context / hermes_memory / context / runtime 共 51 项通过。覆盖 Unicode 全量续读、失败不推进、重启恢复、接纳回执丢失、重试上限、执行中来新资料、Dream 不被连续录音饿死和旧空记忆修复。
- `swift test --package-path Packages/MoMoAgentAgentClient --scratch-path tmp_agent_output/agent-tests -j 2`：106 项通过。
- XcodeGen 2.46.0 生成校验；Mac Release arm64 构建通过。安装包签名与原有正式版 designated requirement 一致。
- `uv run --python <现有私有 runtime Python> python Tests/AgentRuntime/memory_review_live.py --help` 查看真实模型测试参数。正式验收使用隔离 profile、合成资料和现有配置的 Codex gpt-6.1-sol，五项通过：聊天真实写入、未知说话人项目上下文写入、Dream 回执、新原生会话准确回忆、不把第三方睡眠发言写成用户健康。临时认证副本在 finally 中删除。此测试不是手机实机验收。

## 正式 Mac 交付验收

已安装并启动 Mac 1.38.0，实际 gateway 从 `main-1.38.0/runtime-source` 运行。升级前确认没有活跃用户 admission，再退出旧服务；没有删除录音、聊天、配对或修改系统权限。

真实共享聊天完成 4 批增量整理，其中 3 批调用原生 memory 成功写入，1 批明确无需改动，cursor 已到当前消息末尾。普通空闲调度触发的首轮 Dream 已完成，结论为 no_change；随后第一批真实录音也有原生 memory 成功回执。旧录音的其余批次继续后台整理，不能把首批成功说成所有历史已处理。记忆页已核对真实内容、自动整理状态及 Dream 时间。

本机证据：`/Users/syh/Workspace/MoMo-Agent-deliveries/main-1.38.0/validation/installed-memory-validation.json`（只含状态和数量，不含聊天/录音正文）。同目录保存测试日志及合成资料真实模型验收结果。没有将合成测试事实写入用户 profile。这次不重新安装手机、手表，也不声称进行了手机实机验收。
