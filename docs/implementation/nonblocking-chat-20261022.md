# 持续聊天与 Hermes 后台执行

范围：Hermes 分支的 Mac / iPhone 远程聊天。基线为 `c9c174bae31a651b29d54358838a0cb4a7c8d61f`；先在独立 checkout 开发，用户确认后与 `codex/hermes-app-20261021` 的 `5cb04ee1` 整合，保留该分支后续的字号、液态玻璃和设置页改动。

## 采用的现有机制

- [Hermes 原生异步委派](https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation/)：顶层 `delegate_task` 立即返回句柄，执行会话在后台完成；普通后续消息不取消它。
- [Hermes WebUI 的 API 后台结果接收方式](https://github.com/nesquena/hermes-webui/blob/8c6f51ee753edecc4ccc9094ecd026ba171b0c6e/api/gateway_delegation_wakeup.py)：API 客户端负责下一轮，结果先进入原生 `async_delegation_complete` 投递记录，再由客户端触发会话接续。
- [上游结果归属问题](https://github.com/NousResearch/hermes-agent/issues/142957)：只接收当前会话记录，不以可变的全局路由键猜测结果属于谁。

不升级或修改内置 Hermes，不实现新的 Agent 调度器、交互分类界面、配对协议或专属网络通道。

## 实现

运行时为主会话启用原生 `delegation` 工具集。首次启动时补入一次会话规范：日常信息与闲聊直接回应；需要连续调用工具的耗时工作使用原生后台委派，主会话结束当前回复，不循环轮询等待。子任务只获得明确交代的目标、相关上下文和既有授权边界。

共享输入组件始终显示发送按钮，仅空输入禁用；移除停止按钮及其随轮询改变的禁用状态。两端继续使用原来的输入框和消息气泡。

`RemoteTaskStore` 允许连续记录消息，先落盘再发送。投递与状态读取分开，旧状态请求等待期间仍可投递下一条；投递顺序、原操作 ID 和安全重试期限保留。每个 run 分别接收事件，不共用一个 SSE 观察槽。回复按实际接收时间排列，避免先发消息的迟到回复被插到后发消息之前。

客户端读取 Hermes 原生 `GET /api/sessions/{id}/messages`。只消费当前会话的后台投递记录，不展示通知原文；用现有持久投递机制记录一次隐藏接续，模型从原生会话历史读取实际结果后回复。新用户消息在读取期间到达时，接续让位；原生投递行之后已经存在真实用户输入时，该输入已通过 SessionDB 获得结果，不再额外唤醒。投递 ID 与接续操作一起落盘，重启不重复创建。内部接续丢失接收回执时以同一操作 ID 在安全期限内重试；普通用户发送失败仍保留原消息、由用户点击重试。

HTTPS 与 WebRTC 继续共用 `permitted_route`，仅增加原生会话消息的只读路由，限制分页参数；不开放会话删除、任意 API 转发或设置修改。

## 验证

- Swift client：33 个测试通过，包括连续投递、旧读取阻塞时发送新信息、原生结果接续、重新打开去重、已有用户接续不重复唤醒、隐藏接续丢回执后同 ID 重试。
- MoMo runtime：7 个测试通过，包含配置升级的幂等性与用户 persona 保留。
- 连接边界：执行 11 项，7 项通过，4 项因缺少原生 RTC probe / TURN 环境跳过；新增消息读取路由参数边界验证。
- 真实内置 Hermes + 真实 stdio MCP + Swift journal + 本地合成模型：后台工具等待时，信息消息已经收到回复；释放工具后，原生完成记录回到原会话；重新打开无重复接续，工具只执行一次。
- Mac 与 iOS Simulator 目标编译通过；不启动模拟器、不替换已安装 App。

合成模型验证的是调度、状态和投递链路，不证明真实订阅模型始终正确选择委派。主会话仍可执行短工具调用；没有通过自定义工具包装器强制改写每一次 tool use。后台结果的客户端接续在客户端活跃时处理，离开期间执行会话可以继续，回来后再接收结果。未验证真实 Codex / Claude 订阅、真机交互或跨公网连接。

验证日志、结果回执及可应用补丁保存在任务的 `outputs/im-validation/`。本轮构建缓存和合成运行环境验收后清理，保留源码、补丁与必要证据。

合并复验：在 `5cb04ee1` 上完成整合后，重新通过 33 项 Swift client 测试、Mac 与 iOS Simulator 目标编译；日志保存在 `outputs/im-merge-validation/`。本次只合入 Hermes 分支，不安装或替换正在使用的 App。
