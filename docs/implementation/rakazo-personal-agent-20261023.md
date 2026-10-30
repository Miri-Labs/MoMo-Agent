# Rakazo：持续 Personal Agent 的交互与 MoMoAgent 调整

> 本文保留实施前的产品讨论。最终源码映射见 [架构交接](rakazo-architecture-mapping-20261023.md)，本次实际完成度、验证命令与保留边界见 [实施验证](rakazo-implementation-validation-20261023.md)。下文“当前缺失”“待实施”均是改造前状态。

核对日期：2026-10-23。官方仓库 [elie222/rakazo](https://github.com/elie222/rakazo)，固定源码版本 `b088a4c8b5bd694d78b56cf9d87e11d83cccb72f`。本轮阅读实现及测试断言，没有运行 Rakazo，也未把源码审阅当作端到端验证。此文是待实施的产品和工程方案；1.29.5 只交付连接恢复。

## 先纠正产品模型

MoMo 是持续承接用户事项的个人 Agent。用户在手机和 Mac 上面对同一个 MoMo；一句交代留下一个需要负责到底的事项，而非一个随界面消失的请求。理解个人背景、承接目标、后台推进、接受修正、验证交付与主动汇报必须连起来。

一次模型回复结束、一次工具退出、一次委派结束、用户目标完成，是四件不同的事。比如“已交给 Codex”只代表开始执行，不能结束跟进。任务完成事件应让 Hermes 读取真实记录、产物和失败信息，决定继续、询问或交付；用户不必再发“怎么样了”。

Rakazo 的 [VISION](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/VISION.md#L7-L12) 将持续身份、后台完成和返回结果放在产品中心；[同一份文档](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/VISION.md#L38-L61) 明确后端负责运行，前端表达意图和呈现状态，一个 bot 保持一条连续可见对话。

## 实际源码里值得借鉴的机制

| 场景 | Rakazo 的实现 | MoMoAgent 的取舍 |
| --- | --- | --- |
| 跨设备连续对话 | 服务端 bot/thread 为主体，消息有序号；订阅从 cursor 读取持久事件，实时通知只是加速。 | Mac 提供稳定的主对话身份。手机和桌面共享历史；本地只保留草稿、发件箱和缓存。保留可查的旧会话，不直接拼接两端旧日志。 |
| 忙碌时用户继续发消息 | 消息先持久化；可对话的运行接收 steering，其他运行后的未答消息进入 continuation。等待输入卡片不占住整个对话。 | 发送始终可用；补充和取消传给所属任务，独立问题可继续处理。不能每发一句就停止旧工作，也不能把所有话都堆在一个长任务后。 |
| 外部 Agent 完成 | 持久化外部状态；按 generation 创建唯一续跑，提示 Agent 通过工具读取结果；排队失败有 reconciler 补偿。 | 将“完成后的续跑”移到 Mac。复用 Hermes 的运行、委派与会话机制；补充缺失的投递状态，不另造多租户调度平台。 |
| 委派结果回来 | 普通状态更新不抵消最后的结果回报；有稳定 delivery key，失败后可补发，避免双重唤醒。 | “进行中”与“最终结果”分开。工具完成但未向用户交付时，事项仍未结案；重复完成事件不能重复执行或重复回复。 |
| 通知 | 先提交结果消息/未读状态，再通过 Expo 发推送；无 token、发送被接受、回执结果有区别。 | 会话回复和 iOS 通知分开。先确保离线期间已生成并保存回复，再接 APNs。推送失败不影响消息；不能声称 Tailscale 能唤醒 iOS。 |
| 主动跟进 | Routine 是计划执行的 prompt；变更监测先比较基线，只在变化时触发模型。scratchpad 明示不负责唤醒。 | 任务完成/失败直接触发；用户明确约定的后续由 Hermes 调度。转录、健康资料只作为上下文，不因每次同步就打扰用户。 |
| 界面表达 | 对话呈现有效进展、成果和需要用户介入的事项；执行详情按需展开。 | 保留 Dots 三点等待和现有设计组件。模型先给简短回应；后台工作用紧凑状态，结果回到对话中，不显示内部运行 ID。 |

源码：
- [消息提交、steering、订阅补齐](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/db/src/events.ts#L393-L557)，[按游标读取持久事件](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/db/src/events.ts#L1842-L1887)。
- [外部 Agent 结束后的续跑](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/cloud-agent-poll.ts#L275-L390)，[自动返回委派结果](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/bot-messages.ts#L324-L396)，[漏投递修复](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/job-reconciler.ts#L274-L359)。
- [结果入库后再通知](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/executor.ts#L8394-L8458)，[Expo 发送与回执](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/expo-push.ts#L489-L541)。
- [变化触发](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/routine-watch.ts#L606-L684)，[scratchpad 不是调度器](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/scratchpad-context.ts#L9-L25)。

## 网络、Agent、电脑操作分别是什么

Rakazo 的手机端可以设置 server URL，先探测服务，再登录到同一后端；允许局域网/100.64.0.0/10 范围 HTTP，公网要求 HTTPS。在核对的这些路径中，没有发现双端内嵌 TailscaleKit 或一套需要替换我们的扫码建联协议。允许 Tailscale 地址不等于内置 Tailscale。

[手机 server 页面](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/apps/mobile/app/server.tsx) · [地址校验](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/apps/mobile/lib/endpoint.ts)

它的 Pi runtime 在 API/worker 进程中驱动模型和工具；computer provider 再决定使用本机、Docker 或云电脑。Electron 的本机桥接是经过本地授权的 HTTP/NDJSON 服务，通过 `host.docker.internal` 给 app 管理的本地后端使用。连接远端服务不会自动开放当前电脑。这是电脑能力的接入边界，不是手机到 Mac 的 NAT 穿透方案。MCP 则是可选工具接入之一。

[computer runtime](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/docs/computer-runtime.md) · [worker 装配](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/apps/worker/src/index.ts) · [本机桥接](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/apps/desktop/src/host-computer.ts)

我们保留以下分工：

```
手机 / Mac UI
  ↓ 同一个 MoMo、消息和事项；设备只缓存和展示
Tailscale 私网 + MoMo 配对鉴权
  ↓ 只解决连接，不拥有任务
Mac 上的对话与任务协调
  ↓ 接收用户消息 / 工具完成 / 用户授权的定时事件
Hermes 原生会话、记忆、工具与后台任务
  ↓
本机工具 / MCP → cua-driver / Codex 等执行者
  ↑ 真实结果 → Hermes 核对并继续 → 同一对话中的回复
  └ 独立通知投递 → iOS APNs（待接入）
```

不引入 Rakazo 的 Pi、Postgres、Graphile Worker、多 bot、Space、ticket board、Docker 或云电脑作为本版依赖。借鉴职责和状态处理；Hermes 已有的机制继续使用。Rakazo 使用 Apache-2.0；本轮没有移植其代码。

## 当前实现确实缺了什么

本地源码核对：

- `RemoteTaskStore.init` 在没有本地日志时各自生成 session ID；`desktop-tasks.json` 与手机 `tasks.json` 独立。所以“同一个 Mac 执行”目前不等于“同一段对话”。
- `RemoteTaskStore.receiveBackgroundResults` 在前端刷新时发现 `async_delegation_complete`，再创建一次隐藏请求。手机关闭且没有对应前端刷新时，不能靠这条路径持续负责。
- Hermes 的 API-server 委派回传故意只写 delivery row，以免自行越过待确认状态；`gateway/wake.py:persist_delegation_delivery` 写明了这个边界。不能删掉保护然后对每个工具结果盲目 self-POST。
- SSE 目前主要观察本地已知 run；仅补“自动续跑”还不够，客户端还需要读取服务端新生成的回复。
- 1.29.5 修复失效的内嵌网络会话与重试展示，没有解决上述产品闭环。

## 这版怎么落地

先完成“一个 MoMo，把一件事做完并交代”的最小闭环。

1. **同一主对话。** Mac 持久保存产品 conversation ID，配对后两端使用该身份；将可见对话与 Hermes 内部压缩后的 session ID 解耦。历史按稳定消息 ID/分页读取。旧会话原样可查，待发送消息不换身份、不重发。
2. **Mac 负责续跑。** 复用原生委派完成事件及队列，关联原任务和用户授权；记录事件去重键、待处理状态、最终回复 ID。成功入队只是接收，回复落库才是交付。重启补查未完成投递，不重放未知结果的外部写操作。
3. **保持能聊天。** 长工具/委派占用的是该事项，不锁住输入框。先接收消息；Hermes 可安全接收的补充作为 steering，否则由协调层排入后续对话。待确认的事项保持卡片，独立问题仍能回答；同一电脑需要独占的操作继续排队。
4. **结果由 Hermes 解释。** 完成事件只携带可信的本地标识、状态和结果引用。Hermes 读取原目标、已完成内容和证据，核对后继续执行或直接报告；失败也给出明确交代。工具文本不得伪装用户授权。
5. **回复自动到两端。** 持久消息与未读状态为准，在线增量订阅，断线后续读。系统推送独立重试，只提示结果或需要帮助；无变化不推送。“已保存”“推送被接受”“用户已读”分开。
6. **个人上下文保持现有简化。** 转录和健康按既定来源同步/权限规则供 Hermes 使用，长期记忆继续 MEMORY.md / USER.md / session_search。未完成事项由运行状态负责，不能只写进 MEMORY.md 就当作会自动追踪。

连续对话不等于把所有历史塞入每一轮。保留原文与产物，使用 Hermes 原生压缩和检索。

锁屏推送建议由一个很小的通知网关保管开发者 APNs 凭据；不能把团队私钥打进每位用户的 Mac。Mac 仅提交已配对设备的通知标识和“MoMo 有新回复”这类提示，正文继续经 Tailscale 从 Mac 读取。网关不运行 Agent，也不承载聊天流量；不启用网关时仍可后台完成并保存回复，但不能承诺锁屏提醒。APNs 接受请求不等于用户看到，静默后台通知也不保证送达，因此不能靠手机被唤醒才完成任务。[Apple：服务端发送](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) · [后台推送限制](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)。这是产品建议，尚未部署通知服务。

## 实际对话应是什么样

- 用户：“把刚才录音里答应的方案整理好，完成后告诉我。”
- MoMo：“我先核对录音里的要求，再整理成方案。”（真实模型回应，然后开始工具）
- 用户离开 App。Mac 持续执行，进展无变化时安静。
- 用户中途：“先做中文版。”这条补充有明确接收状态并作用于原事项。
- 外部执行结束 → Mac 接收完成事件 → Hermes 读取文件、检查要求。
- 若仍缺东西，继续做；若需要用户选择，问具体问题；若已完成，在同一对话回复：“中文版已整理好，包含……［查看方案］。”再按通知设置提醒手机。
- 用户回来能看到完整结果，Mac 上也看得到。不会只看见“已启动”，也不需要再发一遍任务。

Rakazo 的进度规则本身偏安静：仅长任务发布少量中途消息，不主动播报每一步；它甚至不要求开始前先报一句。我们保留用户已经明确要求的“长任务先简短回应”，借鉴它抑制低价值进度消息的做法。[进度规则](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/executor.ts#L9492-L9520)

## 验收主线与必要边界

以下是待运行的验收，不是本轮通过记录：

- 手机发出任务后退出 App，Mac 完成执行、核对并主动回复；手机重开与 Mac 显示同一条结果。
- 执行期间发补充、独立问题、取消；不丢消息、不把补充错当新任务、不越过待确认状态。
- 同一个完成事件重复投递，只产生一次逻辑续跑和一条最终回复。
- 在“结果已保存但未排队”“已回复但通知未发”处重启，分别补排和补通知，不重跑原外部操作。
- 委派失败、超时或只返回“启动成功”时不标记用户目标完成；已有结果可检查。
- 断网不等于任务失败；Mac 睡眠显示不可达，恢复后再推进。推送失败不丢消息。
- 对话压缩后完成事件回到正确的连续会话；撤销设备不再向该设备投递。

Rakazo 的测试文件明确覆盖了多项上述边界，尤其接受回执丢失、重复唤醒、排队失败、重复状态更新和最终回报区分。本轮只阅读其断言：[cloud-agent 数据库测试](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/cloud-agent.postgres.test.ts)、[委派回报测试](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/adapters/src/bot-messages.test.ts)、[steering 恢复测试](https://github.com/elie222/rakazo/blob/b088a4c8b5bd694d78b56cf9d87e11d83cccb72f/packages/db/src/steering-replay.postgres.test.ts)。
