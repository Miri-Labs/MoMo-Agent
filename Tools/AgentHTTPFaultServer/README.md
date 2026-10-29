# J17 本机 HTTPS 故障端点

服务只监听 `127.0.0.1`，通过真实 TLS 和 HTTP/1.1 chunked SSE 为生产 Provider / Pi / Host 测试提供受控响应。Python 标准库负责服务和客户端，OpenSSL 生成两天有效的临时 CA 与服务证书。脚本不读取 `.env` 或真实密钥。

这是故障端点，响应是固定合成内容。它不证明模型质量、App 恢复或取消后计划没有落库。这些结论需要运行产品测试并检查真实持久化状态。DNS 失败、系统网络切换和设备行为另测。

## 启动与清理

以下命令从仓库根目录运行。`J17_ROOT` 指向本次唯一证据目录；已有输出目录会拒绝复用。

```sh
J17_ROOT=/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/j17-http-fixture
uv run Tools/AgentHTTPFaultServer/run.py prepare --output "$J17_ROOT/tls"
uv run Tools/AgentHTTPFaultServer/run.py serve --tls "$J17_ROOT/tls" --output "$J17_ROOT/service" --config Tools/AgentHTTPFaultServer/short-timing.json
```

`service/ready.json` 给出实际端口、进程 PID、CA 路径及配置时序。进程前台运行；外部编排器可用 `subprocess.Popen` 启动，确认 ready 文件出现后再启动测试，在 `finally` 中向这个自有进程发 SIGTERM 并 `wait`。终端运行时按 Control-C；服务停止后写 `stopped.json`。SIGKILL 无法执行清理。

根任务确认后，可以创建专用模拟器并只修改它的信任。不要在日常模拟器、主机 Keychain 或用户手机运行导入命令。

```sh
xcrun simctl create MoMo-J17-Temporary com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0
# 将返回的 UUID 保存为 J17_SIM，再执行：
xcrun simctl boot "$J17_SIM"
xcrun simctl bootstatus "$J17_SIM" -b
xcrun simctl keychain "$J17_SIM" add-root-cert "$J17_ROOT/tls/ca.pem"
```

本机 `simctl help keychain` 已确认 `add-root-cert` 可用，已安装 iOS 27.0 运行时。导入 CA 后是否通过 App TLS 连接，仍需产品测试确认。未经导入的模拟器可作为 TLS 信任失败子例。

测试完成后，先停止并等待服务退出，再关闭、删除这个专用模拟器，最后删除测试证书。

```sh
xcrun simctl shutdown "$J17_SIM"
xcrun simctl delete "$J17_SIM"
uv run Tools/AgentHTTPFaultServer/run.py cleanup-tls --tls "$J17_ROOT/tls"
```

CA 私钥在签发服务证书后立即删除。CA 与服务证书显式包含 Subject Key Identifier，服务证书的 Authority Key Identifier 指向 CA，以通过严格 X.509 校验。服务私钥为 `0600`，TLS 目录为 `0700`。`cleanup-tls` 仅接受带本工具 marker 且文件名集合匹配的目录；不会清理证据日志。测试被中断后，编排器仍负责停止自有服务、删除专用模拟器和 TLS 目录。

## 产品测试接口

每个独立子例生成新的 UUID。把以下地址作为 OpenAI completions provider 的 baseURL：

```text
https://127.0.0.1:<PORT>/runs/<RUN_UUID>/<SCENARIO>/v1
```

模型名可设为 `j17-synthetic`。唯一接受的鉴权值是合成测试值 `Bearer momo-j17-synthetic-only`。请勿输入真实 Key。请求需有 `stream: true` 和 `messages` 数组，最大正文 2 MiB。服务在内存检查协议，不保存请求 headers、body、模型名、工具结果或密钥。

| 场景路径 | 固定行为 |
| --- | --- |
| `success` | 中文文本 SSE，`stop`，`[DONE]`，完整 HTTP 结束 |
| `success-tools` | 请求一次 `search_transcripts`，收到相应 tool result 后回复文本 |
| `auth-401` / `auth-403` | 每次失败，附 `x-should-retry: true`；由产品证明鉴权不被误重试 |
| `retry-429-seconds` | 首次 429 + 整数 `Retry-After` 秒数，随后成功 |
| `retry-429-date` | 首次 429 + HTTP-date，随后成功；HTTP-date 按整秒编码 |
| `retry-429-ms` | 首次 429 + `retry-after-ms`，随后成功 |
| `retry-429-over-budget` | 首次 429 + 86400 秒，随后成功；由产品证明不会绕过或等待超预算信息 |
| `retry-500` / `retry-503` | 首次对应 5xx，随后成功 |
| `always-500` / `always-503` | 每次对应 5xx，用于检查重试次数上限 |
| `headers-delay` | 读完请求后等待，再发送 HTTP headers |
| `body-delay` | 立即发送 headers，等待后发第一字节正文 |
| `stream-stall` | 发送有效 SSE 及少量正文，等待后继续 |
| `continuous-drip` | 持续发送有效 content delta；总时长大于单次流空闲期限 |
| `disconnect-midstream` | 半截 SSE JSON 后断开 socket，不发送 HTTP 结束 chunk |
| `fragmented-text` | 中文 UTF-8、SSE 行界按单字节 HTTP chunk 拆开 |
| `fragmented-tool-json` | `search_transcripts` 参数拆成两个 delta，每段再按字节分片 |
| `late-tool-after-cancel` | 只发送半截工具参数；收到外部 release 后才尝试发送余下参数及完成标记 |
| `privacy-success` | 与成功响应相同；额外在内存检查实际收到的编码请求，提供 J25 白名单检查结果 |
| `privacy-late-tool-after-cancel` | 与迟到工具场景相同；提供相同的 J25 出站检查 |
| `controlled-long-stream` | J22 持续 SSE；鉴权的 `disconnect` 控制只中断本 run 的 socket；达到时限也断开，永不伪装完整回复 |

`success-tools` 与工具分片场景使用只读搜索工具，参数来自可选配置 `toolArguments`，仅含非空 `query`。外部验收检查调用结果、提交状态和取消后没有执行；不再生成计划。

`short-timing.json` 提供秒级诊断：等待 8 秒，滴流 12 秒、间隔 0.1 秒。外部编排器可复制配置到本次证据目录，调整产品总期限和空闲期限对应的等待值。服务拒绝超过 600 秒的等待 / 滴流总时长。不改变生产预算来迁就端点结果。

## 时序证据与迟到事件

```sh
uv run Tools/AgentHTTPFaultServer/run.py counts --ready "$J17_ROOT/service/ready.json" --run-id "$J17_RUN" --scenario stream-stall
uv run Tools/AgentHTTPFaultServer/run.py release --ready "$J17_ROOT/service/ready.json" --run-id "$J17_RUN" --scenario late-tool-after-cancel
```

对应 HTTPS 接口为 `GET /runs/<UUID>/<SCENARIO>/counts` 和 `POST /runs/<UUID>/<SCENARIO>/release`。release 要求同一个合成鉴权值；其请求不计为模型调用。

取消旅程应先观察 `awaiting_release`，在 App 发起并确认取消，再调用 release，观察 `late_tool_attempted`。如果超出配置等待时长而未 release，服务记录 `release_timeout` 并断流，不生成“已测试迟到”的结论。网络层可能仍接受已关闭连接的首次写入；字节写入成功不证明 App 接收或执行工具，必须检查产品状态。

`events.jsonl` 和 counts 只包含 run UUID、固定场景名、模型请求序号、固定事件名、monotonic 时间、HTTP 状态与字节数。counts 另提供请求次数、响应正文累计字节数和状态序列。`headers_sent` 指 headers 写入本机 socket；`body_sent` 只计 SSE payload 字节，不含 HTTP chunk framing、TLS 或网络开销。它们不是远端接收确认。

每个 run UUID + 场景分别计数。首次失败后成功的计数保存在服务内存；重启服务会丢弃计数，外部编排器必须开启新 run，不能把两次服务进程的请求串成一次重试验收。

## iPhone 宿主集成测试

`Tests/iPhoneIntegrationTests/AgentHTTPFaultIntegrationTests.swift` 通过实际 `ProviderAccess.open`、生产 Pi runtime、`PiAgentHost` 和 `AssistantModel` 运行。外部编排器把 `MOMO_HTTP_FIXTURE_PORT=<PORT>` 注入目标 xctestrun 的 `EnvironmentVariables`，只选择 `MoMoAgentIntegrationTests/AgentHTTPFaultIntegrationTests`。变量缺失时明确跳过；端口不是 1～65535 的规范十进制整数时直接失败。测试仅构造固定的 `https://127.0.0.1` 地址，不能指定外部主机。Xcode 会把 URL 形状的启动环境值按路径处理（`https://` 变为 `https:/`），因此不通过该字段传完整 URL。

这 16 个命名测试需要 `short-timing.json` 的时序，测试 Host 的 transport policy 固定 headers / first byte / idle 2 秒、total 6 秒、最多 2 次 HTTP 尝试、单次 retry delay 上限 1 秒。它们检查 401 / 403 设置入口状态、503 重试上限、429 秒 / HTTP-date / 毫秒间隔、超预算 retryAt 的立即重试及重开、客户端可观察的等待响应 / 正文空闲 / 总期限、半途断开和分片中文。HTTP-date 按服务 snapshot monotonic 时间与客户端墙钟采样推导整秒等待，允许 100ms 本机采样误差。

`body-delay` 不是 iPhone 上独立 `.bodyFirstByte` 期限已通过的证明。已留存的 iOS 27 探针显示 Foundation 可能等到首段正文才交付响应头；当前宿主用例 `testSentHeadersWithoutBodyStillBoundClientResponseDeadline` 因此要求 2 秒 `.responseHeaders` 失败，并核对服务已发 headers、开始等待正文、累计 0 正文字节。真正收到原生 `fetchResponse` 后的 `.bodyFirstByte` 状态由 SDK 桥测试独立覆盖。每种 timeout 的白名单客户端阶段与耗时、服务 counts 都附在 xcresult 中；换 runtime 必须重新核对观察，不能把两个阶段混算为四阶段 HTTPS 全通过。

`testPiFailureRestoresRetryAtAcrossSimulatedHostMetadataCommitGap` 先完成真实 HTTPS 429 失败，再关闭 Host、清空这次测试 `session.json.failure` 并把 state 改为 active，模拟 Pi 已提交而 Host metadata 尚未提交的边界。它检查重开能从 Pi 持久化诊断恢复未来 retryAt。这个子例是受控元数据边界模拟，不能登记为强杀恢复。

每例使用独立 Keychain service 和 `tmp/http-fault-workspaces/<UUID>`；teardown 删除合成凭据并关闭 Host。外部编排器确认宿主进程停止后再删除这些 SQLite 目录。测试把白名单 counts 放入 xcresult 附件，服务日志保留在本次目录。Swift 构建和测试由根任务统一运行；Python 自检不替代这组验收。

工具正对照使用合法的无引用合成计划（`sources: []`）：分片参数必须保存一份 revision 1 的计划。取消测试使用同一参数：等 `awaiting_release` → App 确认取消 → POST release → 观察 `late_tool_attempted` → Archive 没有计划 → 重开仍为取消且无新增 HTTP。这只验证无引用合成计划的取消屏障，真实资料引用由其他旅程覆盖。

## J25 编码后出站检查

`AgentOutboundPrivacyIntegrationTests` 包含三个单独的宿主测试：

- 通过真实 PCM 文件、Archive 收件、合成转录提交与投影建立资料，再用生产 Pi / ProviderAccess / URLSession 发请求。检查三份允许正文（两份近期资料和选定来源）与当前版本到达；三小时前、未选定资料的正文标记、PCM 文件内原音标记、Keychain 合成密钥均不在请求正文中。资料处理前后的请求计数也要为零。
- v1 已经真正发出后，将 Archive 修订为 v2；原会话和重开后的原会话都必须在 HTTP 前拒绝。清理失效会话后新建聊天，真实第二次请求只含 v2。历史第一次允许发送的 v1 保留为证据，不承诺撤回已发请求。
- 正式请求等待半截工具流后取消，再从服务端释放迟到工具。立即重试同一个 admission、关闭 / 重开后再重试都不能发送第二个请求，也不能保存计划。

仅 `privacy-*` 场景开放 `GET /runs/<UUID>/<SCENARIO>/inspection`。服务对实际收到的 UTF-8 JSON body 检查固定 ASCII 哨兵、完整音频 base64 的三种字节对齐哨兵、消息内容类型，以及系统上下文中的来源 UUID / 版本；同时核对实际请求路径、Host、JSON 类型和合成鉴权。响应仅含上述布尔值、计数和来源标识，不返回 arbitrary body / prompt / headers / key；检查结果留在内存，由宿主导出为 xcresult 白名单附件。其他场景不采集这些信息。正常 `events.jsonl` 格式不变。

从本次重新构建的产物启动，新增源码需要先运行 `xcodegen generate`：

```sh
uv run Tests/Support/run-http-agent-e2e.py \
  --test-class AgentOutboundPrivacyIntegrationTests \
  --xctestrun "$J25_XCTESTRUN" --products "$J25_PRODUCTS" \
  --simulator "$J17_SIM" --ready "$J17_ROOT/service/ready.json" \
  --output "$J17_ROOT/j25-unique"
```

本组验证实际编码出站内容与本地普通文件未包含合成 Key；不使用真实密钥、不调用外部付费模型，也不替代 J25 的真机锁定状态、文件保护和备份验收。尚未运行的宿主结果必须记为未执行；Python 自检只证明 inspection 能正确发现合成泄漏，不能证明产品请求已通过。

## J22 并发宿主用例

`ConcurrentWorkloadIntegrationTests` 的执行范围和证据解释见 [J22 验证说明](../../docs/implementation/j22-concurrent-validation.md)。该组服务用 `concurrent-timing.json`（0.1 秒滴流、120 秒硬上限），不使用 J17 的 12 秒配置。客户端总期限为 90 秒；XCTest 240 秒上限只对该组生效，J17/J25 的期限不变。

`POST /runs/<UUID>/controlled-long-stream/disconnect` 要求相同合成鉴权。服务记录 `disconnect_requested` / `forced_disconnect`，该控制不计为模型请求。未收到控制时持续滴流；客户端取消会关闭自己的 URLSession 请求。服务达到上限后记录 `controlled_stream_expired` 并断开，不发 `[DONE]` 或完整 HTTP 结束；宿主必须把这种超时结束视为场景失败。

```sh
uv run Tests/Support/run-http-agent-e2e.py \
  --test-class ConcurrentWorkloadIntegrationTests \
  --xctestrun "$J25_XCTESTRUN" --products "$J25_PRODUCTS" \
  --simulator "$J17_SIM" --ready "$J17_ROOT/service/ready.json" \
  --output "$J17_ROOT/j22-unique"
```

## 自检

```sh
uv run Tools/AgentHTTPFaultServer/test_server.py --output "$J17_ROOT/selftest-unique" -v
```

自检使用真实 localhost HTTPS、合成请求和固定脚本，覆盖证书信任、私钥权限、状态 / 重试头、不同延迟阶段、停滞 / 滴流、非完整 HTTP、中文 / 工具分片、外部释放、路径隔离和日志白名单。它不运行 Swift 构建、App、Pi、ASR 或付费 API。自检 CA 在结束时删除，日志保留在指定目录。
