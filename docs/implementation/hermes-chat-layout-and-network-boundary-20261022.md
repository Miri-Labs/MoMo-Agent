# 聊天进度对齐与网络边界核对：1.22.1

分支：`codex/hermes-app-20261021`，只提交到该分支。

## 进度与测试回复

`ClientTaskActivity` 的展开内容原来按文字宽度参与 `DisclosureGroup` 布局，整块被居中。现在将内容撑满可用宽度并使用 leading 对齐，多行文字也按 leading 排版。手机和 Mac 复用同一个修复，工具状态、错误提示、重新连接和离开聊天提示保持既有行为。

`MOMO_REMOTE_RECORDING_OK` 来自 `Tests/AgentRuntime/remote_fixture.py` 的合成模型固定回复，是旧测试用来断言远程任务完成的标记，不是产品功能。已从生成源删除，相关检查改用自然语言结果、服务端 completed 状态和真实文件。`录音依据` 是原文引用链接，继续保留。已有合成测试会话的持久化历史不会被此次修改重写，也不在生产渲染器按字符串过滤模型正文。

## 网络层与 Agent 的边界

这里区分两类供应商：提供手机到 Mac 可达性的隧道服务商，以及提供模型推理的服务商。

### 手机到 Mac：生命周期分离，隧道供应商可替换

当前链路：手机 `MoMoAgentClient` → HTTPS / SSE → `AccessService` 配对鉴权与受限代理 → 本机 Hermes 任务 API。Mac 桌面分别持有 Access 与 Agent 子进程；隧道只转发 Access 端口，不暴露 Agent 管理密钥。

- `Apps/MacApp/Access/tunnel.py` 只管理连接器、外部 HTTPS 地址、连通性和退避恢复，不导入或控制 Hermes 执行、会话、记忆、任务数据库。
- `TemporarySSHTunnel` 包含 localhost.run 的命令和地址解析；`ExistingHTTPSTunnel` 接受通用 HTTPS 根地址。服务商差异留在这一层，配对、HTTP/SSE、任务协议不判断 Cloudflare/ngrok 等品牌。
- `AccessService` 负责端点身份核对、设备凭据、路由白名单、幂等键和 SSE 续读游标转发，不因切换入口提交、停止或重建任务。
- `RemoteTaskStore` 持久化会话和 operation/run ID。离开页面或取消本地 HTTP 观察只断开观察，停止远端工作走单独请求。

这里的“供应商无关”有明确协议条件：入口必须提供手机可用的 HTTPS，支持 SSE 及时转发、无响应缓冲，并兼容 App 的配对鉴权。当前只内置一个自动临时连接器；其他供应商的连接器由用户管理。地址改变仍需要更新手机的连接入口，不承诺凭空发现新域名。

客户端仍消费 Hermes 的 `/v1/runs`、事件格式和 `X-Hermes-Session-Key`，这是执行协议依赖。更换隧道不需要修改 Agent；替换为另一个不兼容的 Agent 引擎仍需协议适配，不能称为任意引擎零改动。

### 模型服务：尚未完全供应商无关

`DesktopModel.startAgent` 当前将 `model.provider` 写为 `custom`，保存 `OPENAI_API_KEY`；`verifyModel` 在桌面模型对象内直接请求 `chat/completions`，验证 `choices`。因此 Mac 首次设置目前只覆盖 OpenAI 兼容协议，不能据此宣称已支持任意原生模型协议。

内置 Hermes 已有按 `api_mode` 注册的 `ProviderTransport`（Anthropic、Chat Completions、Codex、Bedrock 等）和规范化响应，但其基类明确只抽象格式转换；SDK 客户端、凭据、流式处理和重试仍由 Agent 持有。这不等于完整独立的模型网络层。

后续模型接入应复用 Hermes 的供应商配置、验证和适配能力，由桌面只传配置和呈现结果；不在 UI / `DesktopModel` 继续加入逐供应商 URL、鉴权、流式解析和重试分支。本次按要求核对边界，没有将其描述为已完成的模型层重构。

## 验证范围

`AccessBoundaryTests` 使用真实本机 HTTP 服务和 Access 代理，在替换外部与临时入口配置后核对：设备凭据仍有效、workspace/assistant/instance 身份不变、读取原 run、转发 Last-Event-ID、只有一次提交且没有 stop 请求。这是协议边界测试，没有连接实际公网隧道或模型账户。

UI 检查使用隔离的 iPhone 17 Pro / iOS 27 模拟器、合成录音和脚本模型；不使用个人转录。模型脚本不代表真实模型质量。测试中仍运行真实内置 Hermes 和 MCP，并核对手机进程退出后生成文件及恢复原任务。

本轮结果：34 项 Python 运行时测试、23 项 Swift 客户端测试、1 项手机 UI 完整流程通过。UI 用例新增工具文字左边距与提示/标题起点一致的断言，验证最终自然语言结果和原文引用、关闭手机后 Mac 继续保存文件、恢复同一 run ID 与草稿。首轮 XCTest 在建立连接前退出，重启本轮专用模拟器后完整用例通过。

Mac Debug、手机模拟器测试宿主和手机 Release 构建通过。Release 包的 29 项静态检查通过，手机、内嵌 Watch 和 Widget 版本均为 1.22.1；没有测试入口或合成回复标记。共享进度控件静态检查无高等级命中，7 项中等级提示均来自既有发送/停止按钮尺寸或既有记忆证据枚举。本轮没有安装到真实手机或手表，也未重测真实公网供应商与模型账户。
