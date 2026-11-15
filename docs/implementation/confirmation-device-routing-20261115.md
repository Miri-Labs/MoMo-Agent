# 原聊天确认消息与操作设备

2026-11-15，本地实现，未部署。

## 原因与修复

Worker 的 `orchestrator_report(human_action=...)` 会持久化 `ticket.attention`，但只向主 Agent 发内部 relay；主 Agent 还须调用 `orchestrator_reply` 才能写入 MoMo 聊天。原网关仅投影 `waiting_for_input`，因此可能有等待状态而没有确认消息。另外，原投递回执早于 push 入队，入队失败后重试会提前返回。

网关现在从持久工单补发显式任务的活跃确认，复用原 outbound → ProductStore 消息/事件 → PushOutbox，不增加通知服务。按 `attention.triggerId`、原 mandate 或最早关联聊天定位消息，保留 run/message 归属，不投到最新无关聊天。读取完整 open 分页，并复查掉出近期 ended 页的本地等待任务。

以工单、来源 run 和完整问题去重，兼容上游 attention receipt；同一问题重放、重启或换运行时 ID 不重复，问题、设备、链接发生变化可重新通知。消息持久化及 push 入队完成后才记回执；部分失败可在后续同步或上游重试补齐。清除/ready 撤销等待和过时的未发 push，延迟 attention 出站被拒绝。运行时暂不可读返回可重试的 503。inferred 的确认、blocked/failed 追问和 dropped 出站保持静默，显式结果与主动 ready 交付保留原路径。

## human_action 契约与客户端兼容

核对了 `Vendor/SuperAgent/src/app/tools/executor.ts`、`core/assignments.ts`、`core/replies.ts`、`sources/momo.ts`、`app/views/tickets.ts`。没有修改 Vendor 或工具 schema：`human_action` 仍是最多 1000 字符的字符串，省略保留、null/ready 清除，`question_for_trigger_id` 与 attention 问题原样匹配规则不变。

产品提示词要求 Worker 使用可读的精确前缀，不依赖关键词猜测：

| human_action 前缀 | 消息 confirmation 元数据 | 操作 |
| --- | --- | --- |
| `【手机可完成·聊天回复】` | `device=phone, kind=chat_reply` | 在原聊天答复事实/选项 |
| `【手机可完成·服务授权】` | `device=phone, kind=service_consent, urls=[...]` | 打开工具实际返回的 HTTPS 服务授权页 |
| `【需要 Mac 操作】` | `device=mac, kind=local_action` | 到运行 MoMo Agent 的 Mac 操作权限、桌面、安装或接管 |
| 旧字符串/设备未核实 | `device=unspecified, kind=legacy` | 保留原文，不猜设备 |

没有可用的非本机 HTTPS 链接时降为 `missing_consent_link`，不标为手机可授权。提示词要求交代已核实的缺口与权限范围，不虚构入口、连接器、授权链接或二维码；用户回复不能替代服务商同意或 macOS 权限。完成后回原聊天，Worker 核查真实结果再继续。

`messages.confirmation_json` 为可空增量字段，API/history/SSE 输出可选 `confirmation`。旧客户端继续显示完整中文正文；不需要新的按钮。iPhone 与 Mac 共用 `ChatRendererView` 的 HTTPS 链接处理，手机交给父 openURL，Mac 使用 systemAction。没有改 SwiftUI、Enter 发送或能力发现。

## 验证

在临时 data 目录、fixture 工单和假 push provider 中运行；不调用生产触发器、不发送真实聊天、不启动 DSH、不调用系统权限界面。17 个新测试走真实网关投影/HTTP、消息存储、聊天事件和现有推送路径，覆盖漏发、选择、HTTPS/Mac、原始归属、去重/恢复、变化、清除/ready、写入/入队/provider 失败、主动静默、旧回执与分页。HTTPS 用实际共用 Markdown 引擎检查链接渲染，不访问测试 URL。

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --with aiohttp --with cryptography python -B -m unittest Tests.AgentRuntime.test_confirmation_delivery Tests.AgentRuntime.test_superagent_runtime Tests.AgentRuntime.test_push_notifications Tests.AgentRuntime.test_conversation_events
```

结果：**57 tests，OK**（6.202 秒）。Python 3.14 输出部分 SQLite `ResourceWarning`，未导致测试失败。

附加尝试的旧 Hermes 套件没有进入测试：

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --with aiohttp --with cryptography python -B -m unittest Tests.AgentRuntime.test_personal_agent
```

导入旧 `hermes_state` 时缺少 `ruamel`；没有更改全局环境来补依赖。当前 SuperAgent、ProductStore 事件与 push 的上述 57 项验证通过。`git diff --check` 通过。

未构建、安装、重启或修改现场配置，未验证真机/APNs；当前安装的 agent-desktop 不受此本地提交影响。新模块随既有 tracked Runtime 文件打包机制交付。

临时 fixture 自动删除，测试日志收尾删除；没有生成 DerivedData、SPM 或 Python 字节码目录。共享 uv 缓存和其他任务目录保留。收尾磁盘可用约 16 GiB，不声称其他任务引起的空间变化为本次清理成果。
