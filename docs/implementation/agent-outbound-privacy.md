# J25 编码请求范围验证

日期：2026-10-14。状态：隔离 fixture 与宿主测试已实现，iPhone 宿主构建和执行待主任务安排。

测试入口为 `Tests/iPhoneIntegrationTests/AgentOutboundPrivacyIntegrationTests.swift`，运行方法见 [HTTPS fixture README](../../Tools/AgentHTTPFaultServer/README.md#j25-编码后出站检查)。没有改生产系统提示、ContextBuilder、Pi 工具或网络实现；请求从生产 ProviderAccess / PiAgentHost 经 URLSession 发往本机有验证证书的 HTTPS 服务。

## 测试与独立证据

| 用例 | 检查的实际边界 | 当前结果 |
| --- | --- | --- |
| `testEncodedRequestContainsAdmittedTextWithoutUnrelatedAudioOrCredential` | 真实 PCM 接收和合成转录投影不会自行发 API；发起 Agent 后，服务端收到的编码 body 含三份允许正文、当前来源版本和正式提示。三小时前未选定旧录音的正文、原音容器标记及合成 Key 不出现于 plaintext / base64 body；消息内容类型只能是文字。 | 待宿主执行 |
| `testRevisionBlocksOldHistoryBeforeHTTPAndReopenedHostSendsOnlyCurrentVersion` | v1 请求先成功到达；修订为 v2 后原会话在发送前失效，关闭重开仍拒绝。生产清理完成后，新会话的第二次请求只含 v2，没有重放 v1。 | 待宿主执行 |
| `testCancelledRequestCannotSendAgainAfterLateToolReleaseOrHostReopen` | 发送半截工具流后取消，真实 HTTPS 释放迟到数据。已取消的逻辑 admission 在当前 Host 及重开后均不能再发 HTTP；没有计划落库。 | 待宿主执行 |

服务只在 `privacy-*` 场景开启内存检查，真实请求路径必须匹配该 run 的 `/v1/chat/completions`；Host 必须匹配本机监听端口。检查结果由固定字段组成：目的地/鉴权匹配、是否为文字消息、正式规则和上下文是否存在、来源 UUID / 版本、标记命中、请求字节和数量。原始请求不写日志或报告。Swift 测试把服务结果原样作为白名单 xcresult 附件保存，不以发送前的 ContextBuilder 快照替代实际请求。

Python 自检经真实 HTTPS 发送正常与故意包含泄漏标记的请求，证明检查器能识别原文密钥、无关正文及三种 base64 边界中的音频标记，而检查结果不回显这些内容。宿主测试使用固定合成 Key；不会读取 playground 凭据或真实生活资料。

本机已执行：HTTPS fixture 17/17、runner 5/5 自检通过；两份修改后的 Swift 宿主测试通过 `swiftc -frontend -parse`。原始日志在 `tmp_agent_output/20261014-transport-resume/server-selftest-j25-01.log` 与 `http-runner-selftest-j25-01.log`。语法解析不证明类型检查、链接或宿主执行通过，上表三项仍待模拟器证据。

## 范围限制

“无关资料”指三小时前、超出当前两小时自动窗口且未选定的旧正文；另两份近期资料与选定资料构成本例允许发送的三份正文。自动上下文仍按现行合同携带最多八份录音的元信息，不能把此结果描述为零其他元信息。转录文字是合成输入，音频文件通过生产 PCM 编码与收件路径；本组没有运行 ASR 或真实模型推理。

取消后不再发送是指同一已取消 admission、自动后续轮次及重开恢复；测试不声称撤回取消前已发送的正文。资料修订则按产品合同使原聊天失效，必须新建会话使用当前版本。

普通 workspace 文件会检查合成 Key 是否泄漏，覆盖该 run 的 Archive / Pi / WAL / SHM / 临时输入中实际存在的文件；不替代真机未解锁/锁定状态、Keychain 替换清除流程、保护属性、备份排除、实际外网目的地或 DNS/TLS 失效矩阵。完整 J25 仍需分别证明这些范围。
