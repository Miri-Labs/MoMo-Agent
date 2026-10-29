# 历史聊天检索误报个人资料不可用

2026-10-19，用户反馈工具结果显示：`The personal context file is unavailable. Do not claim it was read or saved.`

## 原因

手机出错会话的只读副本显示，报错工具是 `session_search`。该轮请求已经包含 `personal_context` 系统段，个人资料文件也仍存在。

`MemorySessionHistory` 查询所有记录时，共用的 `MemoryPiProjection.userText` 将 `model[0].content` 一律当作内容块数组处理。Pi 的系统消息使用字符串；SQL 随后对字符串块调用 `json_extract`，触发 `malformed JSON`。读取器将这个数据库错误转换为 `AgentPromptError.unavailable`，导致界面和模型误以为个人资料文件不可用。

## 修复

- 用户正文投影先检查消息角色，再区分纯文本与内容块数组，保留应用保存的原始问题优先级。
- 系统消息与工具记录仍参与分页行数和游标计算，但不会作为用户正文解析。
- 聊天数据库失败报告读取阶段和 SQLite 错误码，单独说明历史检索未完成。
- 明确模型输入规则：直接使用程序已经注入的个人上下文，缺少细节时才检索；持久记忆写入仍须执行工具并核对回执。

这与 [Hermes 的记忆机制](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory) 分工一致：核心记忆自动注入，更新记忆与查找历史聊天使用工具。MoMoAgent 保留每条新用户请求更新快照、同一请求及其重试使用固定快照的现有策略。

## 验证

- 手机出错会话副本共 23 条记录，其中 3 条系统消息。原查询复现 `malformed JSON`，修正后的 SQL 和 Swift 读取器均成功读取。
- 34 项本地 Swift 检查通过，覆盖混合消息、历史搜索、分页、共享的记忆整理投影、错误分类、自动注入、重启快照及记忆写入。其中 1 项为临时的设备会话副本回放。
- 真实 Pi harness 配合脚本化模型执行 `session_search`，验证系统提示存在时检索成功。没有调用外部模型服务。
- 使用临时 Swift package 编译真实 Agent、Archive、Contracts 和 Pi 源码，避免解析无关语音模型依赖。
- 原始设备内容仅保留在本任务的忽略目录中，不写入 Git。尚未安装修复版到手机。

本地验证日志位于任务目录 `tmp_agent_output/20261019-context-error/`。
