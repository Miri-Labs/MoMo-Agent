# 阿里云百炼接入与验证

2026-10-14。初版使用北京地域按量付费 API，默认模型 `qwen-plus`。用户在手机设置页输入密钥，应用通过 PiDurableKit 调用模型。

## 地址与接口

共享地址为 `https://dashscope.aliyuncs.com/compatible-mode/v1`。业务空间地址为 `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`。用户可以在设置页修改地址。密钥必须属于同一地域与计费方案，业务空间域名还要求密钥属于该空间。[阿里云 Base URL 文档](https://help.aliyun.com/zh/model-studio/base-url)

百炼预设固定使用 OpenAI Chat Completions。校验器拒绝 Responses、DashScope 原生 `/api/v1`、Coding Plan 和 Token Plan 地址。自定义服务使用独立的 `.standard` 兼容设置。

## Pi 适配

使用官方 PiDurableKit 固定版本 `885ada3f14c17f48da85c3ac8b359e7f81a8b84f` 的 `CustomProvider.Model`。参数如下：

| 配置 | 值 | 用途 |
| --- | --- | --- |
| `api` | `openai-completions` | 调用 `/chat/completions` |
| `reasoning` | `true` | 让 Pi 的 Qwen 兼容分支写出思考开关 |
| `compat.thinkingFormat` | `qwen` | 使用顶层 `enable_thinking` |
| 会话 `thinkingLevel` | `off` | 发送 `enable_thinking: false` |
| `compat.maxTokensField` | `max_tokens` | 使用百炼支持的输出长度参数 |
| `supportsDeveloperRole`、`supportsStore`、`supportsStrictMode`、`supportsReasoningEffort` | `false` | 省略对应的 OpenAI 专用选项 |
| `supportsUsageInStreaming` | `true` | 获取流式用量 |

工具声明放在 `tools` 参数，Pi 执行本地工具并发送工具结果。应用只提供六个资料工具，文本来源仍由 Archive 核验。模型 API 接收用户消息、相关转录文字和工具结果，音频保留在本地。[阿里云 Function Calling 文档](https://help.aliyun.com/zh/model-studio/qwen-function-calling)

## 验证结果

已执行官方 Pi 的 HTTP 序列化探针，检查了实际构造的请求。六项检查通过：目标路径、`enable_thinking: false`、模型名、`max_tokens`、省略 `max_completion_tokens`，以及省略 `store` 与 `reasoning_effort`。探针响应来自本地测试处理器，这项结果只证明适配参数进入请求。

同一检查已加入 `MoMoAgentTests/BailianRequestTests.swift`，用例名为 `bailianRequestSerializationUsesExplicitNonThinkingChatCompletions`。它使用官方 Pi 构造请求，并由本地 `URLProtocol` 拦截；不使用真实密钥。

真实百炼调用尚需测试凭据。完整 smoke 使用合成转录资料，验证自动上下文、本地 `write_plan`、计划来源，以及独立 Keychain service 的写入和恢复。测试不会读取业务项目的 `.env`，也不会覆盖手机应用的凭据 service。

本轮共享包第 19 轮共有 189 个命名测试，188 通过；唯一跳过项就是下述真实百炼 smoke。iPhone 模拟器已通过 OpenRouter 的真实上下文测试（live04 direct，`anthropic/claude-sonnet-4.6`，5/5、无跳过）；该结果不代替百炼的接口、模型或网络验收。此前 live02 为 5/5，live03 因本机代理连接/TLS 错误为 1/5，direct 路径 live04 已复跑通过。收费入口与各场景见 [iPhone 集成测试](../../Tests/iPhoneIntegrationTests/README.md#真实-agent-测试)。

live04 的自动断言通过后，人工复核仍发现最终回答复述过时细节、完整读稿后重复搜索两项语义问题，计划本体未混入旧值。问题记录见[实施状态](status.md)，不把本轮概括为模型稳定无误。

独立凭据回归在模拟器实际写入 Keychain，重开后由本地 URLProtocol 验证生产 Pi 请求仍携带正确 Authorization 头，2 项测试通过；最新 `ios-build-29` / `ios-tests-16` 完整套件再次通过这两项。第 16 轮共 60 项，55 通过、5 项收费测试未注入凭据而跳过、0 失败。模拟器使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`；此前关闭签名造成的 entitlement -34018 已解决。这个本地发包探针不访问百炼或 OpenRouter，也不作为远端鉴权结果。

在具备 Xcode 27 和所需 SDK 的环境，用安全输入或 CI secret 注入 `MOMO_E2E_API_KEY`。可选变量 `MOMO_E2E_BASE_URL`、`MOMO_E2E_MODEL` 覆盖默认值。密钥不要写在命令行参数、脚本或测试输出里。

```sh
if [ -z "${MOMO_E2E_API_KEY:-}" ]; then
  echo '未配置 MOMO_E2E_API_KEY，未执行真实百炼测试。' >&2
  exit 64
fi
swift test --package-path Packages/MoMoAgentKit \
  --filter bailianLiveAPIUsesAutomaticContextAndSavesSourcedPlan
```

只有该用例实际调用成功、计划落库且来源检查通过，才记录“真实百炼 API smoke 通过”。普通 `swift test` 在缺少密钥时跳过此用例。
