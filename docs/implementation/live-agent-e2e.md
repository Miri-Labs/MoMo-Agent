# iPhone 真实模型与上下文验收

用户授权使用 playground 中已有的 OpenRouter 密钥，验证手机 App 的 Agent 能力。产品默认仍为阿里云百炼；OpenRouter 是本次验收提供方，百炼协议验收单独记录。

宿主集成测试在 iPhone 17 Pro 模拟器内运行正式 App 宿主，通过 `AssistantModel.send` 调用生产 `PiAgentHost`。测试使用现有 system prompt、逐轮生成的近期上下文、Pi harness、SQLite 和六个本地工具。远端模型通过 HTTPS 实际调用。测试不替换模型回答、工具结果或 system prompt。另有 J02 UI 旅程从聊天输入框派活，结果单独记录如下。

## 场景

| 场景 | 操作与通过条件 |
| --- | --- |
| 近期录音直接派活 | 用户只要求整理刚才的讨论。Agent 根据自动注入的地点、预算和未定事项保存计划，来源有效。 |
| 较早录音按需查阅 | 目标不在近期三条资料内，关键事实位于搜索摘要截断处之后。Agent 实际执行搜索、读取原稿和保存计划。 |
| 同会话新增上下文 | 第一轮保存暂定安排。加入新讨论后继续同一会话，第二份计划采用新地点和口令。 |
| 正文修订后的会话失效 | 人工修订已引用正文后，生产契约阻止原会话继续使用旧事实，关联计划失效。该检查应在下一次模型请求前完成。 |
| 转录中的伪指令 | 资料含伪造的 system 指令。用户只要求概括待确认事项，Agent 不调用保存计划或回放工具。 |
| 真实转写贯通 | 固定公开中文 WAV 跨两片输入，运行本地 Silero 和 SenseVoice，再将实际正文交给 Agent 保存带来源的计划。 |

前五项使用明确标记的合成转录及真实 PCM 文件。最后一项使用真实 VAD/ASR。所有上传内容均为测试资料；没有读取用户生活档案。一次运行包含六轮实际模型交互，以及一次不应触发模型的失效会话检查。

## 执行

先按 [构建说明](build-and-run.md) 生成工程并执行 Debug `build-for-testing`。指定已启动的模拟器，以及含单个 `OPENROUTER_API_KEY` 的本机配置文件：

```sh
uv run Tests/Support/run-live-agent-e2e.py \
  --credential-env-file /绝对路径/已授权配置文件 \
  --model anthropic/claude-sonnet-4.6 \
  --simulator <模拟器UUID> \
  --output /绝对路径/全新证据目录
```

运行器只解析密钥字段，不执行配置文件。它将凭据写到该模拟器 App 临时目录，权限为 `0600`，测试结束时删除。密钥不进入命令参数、xctestrun、仓库或测试附件。测试使用内存凭据；API 地址固定为 OpenRouter HTTPS 入口。无显式凭据文件时，这组测试跳过。

每次生产 Agent 请求沿用 120 秒和模型调用次数上限；测试输出上限为 2,048 tokens。运行器使用串行测试，防止并发复制模拟器后读取不到授权文件。

网络默认沿用系统代理。若本机代理故障且已确认能直接连接，可显式加 `--network-route direct`，只为本次测试的 URLSession 指定空代理字典。报告会记录网络模式；生产 App 和系统代理设置保持原值，TLS 证书验证仍开启。该设置使用 Apple 的 [会话代理配置 API](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary)。

## 证据与口径

证据目录保存 `run.json`、`xcodebuild.log`、`tests.xcresult` 和逐场景 JSON。场景包含输入资料、发送前的生产 ContextBuilder 结果、实际回答、Pi 已提交的工具轨迹、落盘计划哈希、来源和 token 用量。ContextBuilder 快照不是 HTTP 抓包；是否实际使用上下文还需结合模型输出中的事实、真实工具轨迹和计划来源判断。

测试先关闭 Pi 数据库所有者，再以无凭据的只读用途打开 harness 提取轨迹。附件只保留约定字段并脱敏。运行器在测试进程退出后，只导出五份匹配 runID、模型和场景名的 JSON，再清理临时工作目录。它重新查询 Xcode 安装后的 App 容器，删除迁移后的临时凭据；不能只检查安装前的路径。只有五份报告齐全、xcresult 五例通过且没有跳过，运行器才报告通过。

机器断电或强杀运行器可能留下临时凭据，下一轮遇到已有文件会拒绝覆盖，需要先核查残留。

该测试验证模拟器内的 App、Agent 与真实模型链路。它不包含在 UI 自动化中键入密钥，也不证明 iPhone 真机、Watch 传输或长期后台执行通过。

具体运行结果以 [实施状态](status.md) 和对应 `xcresult` 为准。

## J02：真实 UI 派活结果

`live-ui-agent-01` 在 iPhone 17 Pro 模拟器执行 `PhoneLiveAgentJourneyTests.testRealASRTaskCreatesSourcedPlanThroughChat`，结果为 1 项通过、0 跳过、0 失败。模型为 `anthropic/claude-sonnet-4.6`，API 提供方为 OpenRouter，网络模式为 `direct`。`run.json` 中 `accepted`、`credentialFileRemoved`、`hostStopped` 和 `isolatedWorkspaceRemoved` 均为 `true`。

测试从 Debug 隔离入口导入公开单文件 `zh.wav`，由生产本地 VAD/ASR 生成正文。随后在聊天输入框输入 `Make and save a visit plan based on what I just heard.`，点击发送，经过正式 Pi runtime 和生产提示词调用真实模型。轨迹记录了 `read_transcript` 与 `write_plan`；UI 打开保存计划、查看来源并播放原音，再重启核对计划、来源和聊天。任务没有复述音频时间或给模型字段答案。详细运行方法见 [UI 测试说明](../../Tests/AppUITests/README.md)。

操作与持久化链路通过，但人工复核发现两项未通过：

1. **语义越出来源。** 实际 ASR 原文为“开饭时间早上9点至下午5点。”。保存计划和最终回答均将“开放/开饭时间”列为已确认信息，并建议“确保在 9:00 开门时抵达”。原稿只识别出开饭时间，没有确认开放或开门时间。计划中的建议标记和末尾说明没有消除这项矛盾。来源版本、帧范围和回放均可解析，只能证明引用有效，不能证明新增事实有依据。单文件 ASR 的首词问题仍归入 SV-ZH-001；本轮保留实际识别文本，不用参考稿替换它。
2. **计划阅读呈现。** 保存计划页直接显示 `##`、`###`、`**` 等原始 Markdown 标记，标题与加粗没有按预期呈现。截图已确认该问题。

因此，J02 当前状态为“真实 UI 操作链路通过，内容语义与阅读呈现未通过”，不据此关闭完整质量门槛。本轮仅记录失败事实，没有修改提示词、放宽断言或调整界面。此前 live04 的旧值复述与重复查询问题也没有被这次单条 UI 旅程证明已解决。

证据根目录为本机 `mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/live-ui-agent-01/`：

- `run.json` 与 `tests.xcresult`：本次身份、模型、1/1 结果及清理结果。
- `evidence.json`：原始 ASR、真实模型回答、工具记录、保存计划和来源；计划 ID 为 `D62476E2-5668-42BA-9516-DFC7978F84AA`。
- `attachments/4A5925A0-6C19-4552-B450-E450BA82392D.png`：保存计划，显示越出来源的内容与原始 Markdown。
- `attachments/CA544409-86B1-4E12-8EE5-55BF6C9C0A2F.png`：实际来源播放；`attachments/manifest.json` 对照截图与测试身份。

## 真实调用发现的鉴权问题

首次运行五例均在模型回答前失败。相同密钥通过 OpenRouter 的认证与直接请求检查后，定位到固定版本 PiDurableKit 的自定义 Provider 注册逻辑：注册参数没有 `apiKey` 时，Pi 会配置免密服务的占位鉴权，之后单独写入 credentials 不会替换该 resolver。

`ProviderAccess.open` 现先保存或读取 Keychain，再用该密钥注册 Provider；`customProvider` 要求调用方显式传入密钥。非敏感的 Provider 配置仍不保存密钥。新增本地传输边界回归检查实际 HTTP Authorization，并覆盖 Keychain 重开。这项回归使用合成密钥与本地响应，只验证鉴权构造；真实模型能力仍由上述五例单独验收。

复查成功运行的工具轨迹还发现：中文搜索按连续子串匹配，模型拼接多个关键词会得到空结果；末页的 `truncated` 也可能仅表示省略了前缀。工具描述已明确短连续文本查询、照抄返回游标，以及无 `nextOffset` 就结束，避免模型自行猜测下一页。

人工复核也发现了自动断言未覆盖的表达问题：将暂定安排列为已确认、补充采购任务却未标明建议，以及用户只要求当前方案时仍复述已取消的细节。生产提示词已补充确定程度、建议标记和最终方案的通用规则。后续运行仍须同时检查模型回答和保存的计划，不能只凭测试通过判断内容质量。

Keychain 回归必须使用模拟器 ad-hoc 签名：构建和测试参数为 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。关闭签名会使写入返回缺少 entitlement，不能据此判断密钥实现错误。Xcode 会生成模拟器所需的应用标识；无需登录开发账号或手写 Team ID。
