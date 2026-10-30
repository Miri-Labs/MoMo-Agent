# ADR：Pi 传输失败的结构化契约

日期：2026-10-14。状态：Vendor 补丁已实现，应用层接线与 J17 验收由主任务继续。

## 决定

将 PiDurableKit 的固定上游源码放入 `Vendor/PiDurableKit`，保留许可证和第三方声明。补丁集中在传输、类型和 generation 身份传递，不修改模型内容、提示词或工具执行。依赖与重建步骤见 Vendor 的 `UPSTREAM.md`。

现有 Swift hooks 无法获得完整 HTTP 失败。`errorMessage` 已经丢失结构，不作为业务分类依据。URLProtocol 只用于局部测试。生产失败沿本次模型调用自己的 fetch closure 传递。

## 请求身份

generation prepare 的现有短事务先读取 `LiveDoc.run.inputs` 和各 submission 的 `requestId`，然后才追加系统上下文等表写入。Pi 禁止首次表写入后继续读表，读取顺序是必要约束。这些 `requestId` 就是 Host 已提供的完整 admission key。事务结束前 materialize 普通对象，网络期间不持有该事务。

context 字段：`conversationID`、`taskID`、`requestIDs` 数组、`generationAttempt`、`modelCallID`。前三种 Pi 数值身份转为字符串；`requestIDs` 保留原字符串。`modelCallID` 由 task、generation attempt 和当前 cutoff 构成，随 request checkpoint 固定。

MoMo 按完整 admission key 核对自己的逻辑 requestID 和业务 attempt。SDK 不解析 MoMo 的重试键。业务 attempt 与 Pi generation attempt 是不同层次，不混用。一个生成轮次可能承接多个 submission，所以保留数组。

## 策略与时限

`Settings.Stream.transportPolicy` 可设置默认策略。`Hook.beforeRequestTransportPolicy` 在每次请求前返回策略，覆盖 prepare 的默认值。Host 在这个 hook 中执行现有状态与来源检查，并提供当前操作 deadline。策略不写入对外 HTTP header 或模型 metadata。

默认值：响应头 30 秒、正文首字节 45 秒、正文空闲 30 秒、单次模型调用总时间 120 秒、HTTP 总尝试 2 次、单次重试等待最多 60 秒。Host 可传绝对 deadline，让多轮模型调用共享剩余操作时间。时间预算要求为有限正数且不超过 1 小时，HTTP 总尝试限 1–8。

阶段计时使用单调时间。URLSession 的 `didReceive(response)` 回调到达后移除响应头计时器，启动正文首字节计时器。首个非空 `didReceive(data)` 回调到达后改为空闲计时器，每次原生数据到达重置它。正常 EOF 移除正文计时器。总时限跨重试、等待及正文消费持续有效。

阶段名称描述客户端可观察的原生事件，不是服务端 socket 的写入进度。`body-delay` 端点已发送 headers、尚未发送任何正文时，已留存的 iOS 27 探针显示 Foundation 会推迟 `didReceive(response)`，此时仍由 `responseHeaders` 期限结束请求。不能从服务端 `headers_sent` 推断客户端已进入 `bodyFirstByte`，也不使用仅在完成后可得的 task metrics 追改持久失败类别。该平台行为需要在每个目标 runtime 重验；如果回调行为改变，先保留新原生证据再调整平台预期。

原生 `fetchResponse/fetchData/fetchEnd` 调用当前 pending fetch 的私有 observer，计时不依赖消费者何时读取字节。Node 原生 fetch 单测采用 reader 观测；iPhone 生产走原生到达事件。取消删除原有 pending 映射并调用 `URLSessionTask.cancel()`，迟到回调无法找到旧映射。

## HTTP 重试

传输包装层使用锁定上游的 `retryProviderRequest`；提供方适配器的 `maxRetries` 为 0。整个 modelCall 另有实际 HTTP 次数上限，覆盖适配器额外调用。

- 401/403 立即停止，`x-should-retry` 不能覆盖。
- 429 优先采用有效 `retry-after-ms`，其次 `Retry-After` 秒数或标准 HTTP 日期。返回失败时保留有效的绝对 `retryAtMs`。
- 有效等待超出策略上限或剩余总预算时立即返回失败，不缩短等待再提前请求。
- 408/409、5xx 和可重试的连接失败有界退避。默认首次为 375–500 ms，上限 8 秒，最多实际尝试次数仍由策略约束。
- HTTP 错误正文直接取消，不读入 SDK errorMessage 或持久历史。等待前释放响应正文。
- 成功状态后的流故障不自动重试；未知工具写入由 MoMo 使用原 operationID 对账。

## 失败持久化

利用上游 `AssistantMessage.diagnostics`，写入 `type = pi.transport_failure.v1`。Swift `AssistantMessage.transportFailure` 为 throwing getter，返回 `ProviderTransportFailure?`。不认识其他 diagnostic 时忽略；已知诊断结构损坏时抛错。

`details` 白名单：`context`、`kind`、`httpStatus`、`retryAtMs`、`timeoutPhase`、`nativeDomain`、`nativeCode`、`httpAttempts`、`retryDelaysMs`、`receivedBodyBytes`。`kind` 为 http/network/timeout/cancelled/protocol；超时阶段为 responseHeaders/bodyFirstByte/bodyIdle/total。失败消息是固定安全文案。字段中没有 header、原始错误正文、密钥或 stack。

取消和超时后，即使 provider 迟到送来成功或完整工具，包装层也只发一次失败终态。Pi 已有 signal 检查与 MoMo 的 request/attempt 检查继续控制工具和业务写入。未知写入先对账的业务契约保持原样。

## 验证

Vendor JS 类型检查和 25 个测试通过。覆盖原生桥背压、取消及错误域代码，真实本机 HTTP 的鉴权/限流/退避/四阶段时限，三个实际 provider adapter，以及 Pi submission 身份持久化与每轮 hook deadline。

Swift/JSC 的带 PromptSection 回归在内存库、SQLite 两个参数上先复现读写顺序错误，再验证修复。MoMoAgentTests 的原有保存计划、重启恢复、工具调用和取消断言全部恢复通过；14 个命名测试中 13 个通过，百炼在线测试按 opt-in 规则跳过。

J17 的受控 HTTPS、iPhone URLSession、UI 恢复和真实工具写入去重矩阵见 `docs/implementation/agent-http-failure-audit.md`。它们仍需应用层执行，不能用 Vendor 单测结果代替。

2026-10-14 恢复时将宿主的 `testBodyFirstByteDeadline` 更名为 `testSentHeadersWithoutBodyStillBoundClientResponseDeadline`。测试继续使用 2 秒期限，并同时要求服务已发送 200 headers、开始等待正文、正文累计 0 字节、没有流完成事件及客户端 `.responseHeaders` 失败。未发 headers 的对照仍单独验证。原生桥测试分别验证未收到 response 回调时的 `responseHeaders`、已收到 response 后的 `bodyFirstByte`，以及两者取消后的迟到事件屏障。宿主改动尚待本机模拟器执行；历史 `j17-app-03` 15/16 失败记录保留，不能改标为通过。

本机恢复验证：Vendor JS 26/26 与类型检查通过；真实 loopback HTTPS fixture 15/15、HTTP runner 4/4 自检通过。首次 fixture 运行在 Python 3.13 / LibreSSL 3.3.6 上因证书缺少 Authority Key Identifier 失败，已在签发脚本中补齐 SKI / AKI，再以显式 `VERIFY_X509_STRICT` 复验通过，没有关闭信任或主机名验证。原始失败与通过日志分别保留在 `tmp_agent_output/20261014-transport-resume/`。这些结果仍不包含新的 iPhone 宿主验收。
