# J17 模型接口故障调查

调查日期：2026-10-14。调查对象是当前固定依赖，不据此推断上游其他版本。

本轮真实 API 和实际手机界面的成功链路已通过。J17 的鉴权、限流、流停滞、断流和迟到故障矩阵仍待执行。下述 SDK 补丁已获实施授权，调查结论本身不代表补丁或故障验收已完成。

## 固定版本与源码

- PiDurableKit：`https://github.com/finnvoor/PiDurableKit.git`，commit `885ada3f14c17f48da85c3ac8b359e7f81a8b84f`。
- JS 锁文件：`@earendil-works/pi-ai`、`pi-durable`、`chord`、`pi-codemode` 均为 `1.2.0`；OpenAI SDK 为 `7.19.0`，Anthropic SDK 为 `0.129.0`。
- 上游固定源码导出到 `Vendor/PiDurableKit`，不含嵌套 `.git`。以下 SDK 行号对应补丁前的固定版本。
- npm 原始依赖调查副本保存在本机证据目录 `tmp_agent_output/20261014-momoagent-xcode/j17-source-audit/`。在 vendor 中执行锁定安装后，可在 `JS/node_modules/` 找到相同版本的可读源码。

## 实际行为

| 位置 | 当前行为与影响 |
| --- | --- |
| SDK `Sources/PiDurableKit/Runtime/Network.swift:29` | `request.timeoutInterval = 3600` 覆盖 App 的 30 秒请求配置。 |
| 同文件 64–75、88 | HTTP 状态和响应头完整送入 JS；网络失败却只传 `localizedDescription`，丢失原生错误域和代码。 |
| SDK `JS/src/runtime/fetch.ts:269–292` | fetch 在收到响应头时 resolve。 |
| `openai/src/client.ts:1610–1652`、1033–1040 | 请求计时器在 fetch resolve 后移除；SSE 不走正文解析超时。当前 45 秒配置不能覆盖正文首字节及后续空闲。 |
| `pi-ai/dist/api/openai-completions.js:503` | 将结构化 provider error 格式化为 `errorMessage`。Responses 165–171、Anthropic 716–718 有同类转换。 |
| `pi-durable/dist/harness/generation.js:405–409` | 将失败归并成 `unanswered/model_error`，只保留文本详情。 |
| MoMo `PiAgentHost.answer` | error/aborted 消息不能成为 answer，调用方最终得到 `unanswered`。401/403 无法进入待配置。 |

`onResponse` 只在请求成功返回后触发。错误状态已由 SDK 抛出时不会调用它，因此单独暴露该 hook 不够。

## 已有重试

MoMo 配置 `stream.maxRetries = 1`、`retry.enabled = false`。三个 provider adapter 将底层 SDK 重试设为 0，使用 `pi-ai/dist/utils/provider-retry.js` 的统一重试函数。

- 普通 401/403 只有初次请求。429、5xx、408/409 和部分连接失败最多初次加一次重试。
- 支持 `Retry-After` 秒数、HTTP 日期和 `retry-after-ms`。默认等待上限 60 秒；超过时抛普通 Error，原始状态和重试时间不再结构化可用。
- 没有有效重试信息时，首次指数退避加抖动为 375–500 ms；等待支持取消。
- `x-should-retry: true` 优先于状态码，能使 401/403 重试。helper 有 `noRetryStatuses`，三个 adapter 没有传入。
- Anthropic 还有严格工具 schema 的兼容性降级请求，HTTP 总数不能只看 `maxRetries`。每次形态请求各有自己的重试预算。
- SSE 开始后的失败不属于请求创建阶段，当前 helper 不自动重试该流。
- MoMo 的 12 次限制统计模型生成轮次，不统计轮次内的 HTTP 重试；120 秒总期限另由 Host 管理。

## 维护方式

采用仓内固定上游源码副本，加范围明确的 bridge/native 补丁。保留许可证和第三方声明，从可审查源码重建 bundle，并在 `UPSTREAM.md` 记录修改位置和步骤。

复用上游 `AssistantMessage.diagnostics` 承载版本化结构化传输失败。`pi-durable/dist/harness/generation.js:549–551` 原样保存 assistant message；Swift 当前没有解码 diagnostics，需要补公开类型。只保存状态、原生错误代码、超时阶段、请求身份和计数，不保存认证 header、原始错误正文或 stack。

身份应复用 generation task、submission/request ID 和 checkpoint attempt。每个网络调用独立持有自己的状态，不能通过全局最近响应推断归属。取消、停止后的迟到结果必须经过已有 Pi signal 和 MoMo request/attempt 屏障。未知工具写入先按原 operationID 对账。

现有 Swift hooks 不足以提供结构化 HTTP 失败。URLProtocol 可用于局部传输契约测试，不承担业务失败的持久真源，也不代替受控 HTTPS 验证。

## 可执行故障矩阵

使用真实 HTTPS 故障服务，经过生产 ProviderAccess、PiAgentHost、AssistantModel。客户端使用合成密钥和 fixture。服务器记录请求数及单调时间，客户端导出白名单结构化事件。真实提供方成功与受控故障分别报告。

| 故障 | 断言 |
| --- | --- |
| 401、403，含强制重试 header | 只请求一次，进入待配置，无工具写入；修改配置后显式重试。 |
| 429 秒数、日期、毫秒 | 不早于 Retry-After 再请求；取消等待后没有第二次请求。 |
| 429 等待超预算 | 返回 retryAt，不缩短等待后提前重试。 |
| 连续 500/502/503 | 实际 HTTP 次数和退避有界，无第二层 Pi 自动重放。 |
| 响应头延迟、正文首字节延迟、正文中途停滞 | 期限从客户端实际收到的 response/data 回调计时；无 response 回调时为 `responseHeaders`，收到 response 后无 data 才为 `bodyFirstByte`。每种故障保留服务时序、客户端阶段与耗时，结束时取消网络。 |
| 持续滴流 | 空闲计时器可重置，但总期限仍生效。 |
| 分片中文、工具 JSON、半途断开 | 参数完整且验证成功才执行；未完成参数没有写入。 |
| 取消或总期限后送回完整工具事件 | 计划数不增加，旧 attempt 不影响新请求。 |
| 保存工具已提交、后续流断开、显式重试 | 先对账，最终只有一份计划。 |
| 两会话并行，一次 429、一次成功 | 状态归属正确，取消其中一个不影响另一个。 |
| 真实 DNS/TLS 失败 | 根据原生错误域、代码分类，不解析错误字符串。 |

故障测试使用缩短且明确注入的计时预算，至少保留一项生产默认预算检查。真实手机网络切换与系统挂起后的行为仍需设备验证。

## 恢复后的阶段契约核对

历史 `j17-app-03` 有 15 项通过、1 项失败；失败用例把服务端已发 headers 等同于 URLSession 已交付响应头。交接中记录的 iOS 27 原生探针表明，服务端等待首段正文的 8 秒期间，`didReceive(response)` 可能还未触发，`task.response` 仍为 nil，异步 bytes 入口也未返回。因此 2 秒 `.responseHeaders` 终止符合当前客户端可观察契约，不能记成 `.bodyFirstByte` 已通过。

恢复修改保留 2 秒阶段期限和 6 秒总期限。宿主用例改为核对 `.responseHeaders`、服务的 `headers_sent` → `body_wait_started` 顺序、200 状态及 0 正文字节；同时附加白名单客户端耗时和阶段 JSON。SDK 原生桥另以明确的 `fetchResponse` 回调验证 `.bodyFirstByte`，并增加无 response 回调时超时及迟到回调不产生字节的对照。没有提前发送正文、放宽期限或修改生产传输实现。

旧探针与失败原始文件位于交接所列的另一台机器；本次 Git 检出只有 `evidence/2026-10-14-pause/evidence-index.json` 中的大小、SHA-256 与部分结果摘要，未假定原始日志已迁移。新的本机宿主运行仍是必需验证；当前 runtime 若出现不同阶段，先用原生回调证据调查，不能直接接受任意阶段来使测试通过。
