# 网页搜索与读取

首批支持 DeepSeek、Exa、Tavily。搜索和网页读取分别选服务，用户自行配置 API Key。API 请求直接由 iPhone 发出；不依赖对话模型供应商的内置搜索，也不引入 WebView 或本地 HTML 提取依赖。

## 统一边界

`Packages/MoMoAgentWeb` 的 `MoMoWeb` 提供 `WebAccess.search` 与 `WebAccess.fetch`。三家的地址、鉴权、请求体和响应字段由 `WebClient` 适配；调用方只接收统一的搜索结果、带来源的网页正文及错误类型。Agent 使用 `web_search`、`web_fetch` 两个工具，聊天中展示“搜索网页”和“读取网页”。工具只在配置并启用后提供。

| 服务 | 搜索 | 网页读取 | 鉴权 |
| --- | --- | --- | --- |
| DeepSeek | `/v1/tools/search` | `/v1/tools/fetch` | Bearer |
| Exa | `/search` | `/contents` | `x-api-key` |
| Tavily | `/search` | `/extract` | Bearer |

协议来源核对于 2026-10-19：[DeepSeek](https://api-docs.deepseek.com/guides/search/)、[Exa Search](https://exa.ai/docs/reference/search)、[Exa Contents](https://exa.ai/docs/reference/get-contents)、[Tavily Search](https://docs.tavily.com/documentation/api-reference/endpoint/search)、[Tavily Extract](https://docs.tavily.com/documentation/api-reference/endpoint/extract)。Tavily HTTP 200 仍可能包含失败项，成功列表无正文时返回明确的无内容状态。

## 配置与资源

设置 → 连接与权限统一提供联网总开关、搜索/读取服务选择及三家服务的原页配置。未配置时默认关闭。用户点击“保存并启用”后，成功保存的配置会开启联网，并将尚未选择的搜索、读取服务设为本次保存的服务商；已有的明确选择保留。模型在下一条消息开始时读取配置并获得对应工具，无需重开会话。用户仍可通过总开关主动停用。

旧版已保存但未启用或未选择服务商的配置，重新保存一次即可启用，无需重填密钥；读取配置本身不会覆盖用户主动停用的状态。连接测试分别发起一次公开查询与 Swift 官方文档读取，界面说明计费与每项结果；保存本身不代表接口验证成功。

密钥复用已有钥匙串实现，使用独立的 `MoMoAgent.WebCredentials` 服务。JSON 仅保存连接地址、钥匙串引用及选择状态。更换地址必须重新填写密钥；同地址留空保留原密钥。保存先持久记录新密钥的清理引用，再创建密钥并提交新配置；失败或进程中断后仍能清理孤立密钥，原连接不被覆盖。

配置和钥匙串读写均同步完成后再进入网络等待，不持有文件句柄或数据库连接。每个 WebAccess 最多两项在途任务，请求超时 20 秒、总资源超时 30 秒，响应上限 2 MiB。不跟随 API 重定向，避免密钥转发。停用、改配置和调用者取消都会取消网络任务。

网络层只在内存缓存最多两份正文，120 秒后到期。`documentID` 与字符位置用于继续读取同一份正文，配置变化后立即失效；已进入聊天的工具结果仍按对话历史规则保存。网页文本作为外部资料，不能授予工具权限，引用使用原始来源 URL。

## 验证

- 独立包测试覆盖三家请求与响应契约、空结果与部分失败、JSON 不含密钥、同地址保留与异地址换钥、旧密钥清理、写入失败保留原连接、快照分页、关闭取消、并发上限与 HTTP 错误脱敏。
- `Tests/Support/check-web-settings.sh` 使用 iPhone SDK 编译统一层，并检查实际设置页、字体和颜色组件；不需要语音模型或开发签名。
- 聊天渲染回归使用已有 `chat-renderer-core.test.cjs`。CI 增加独立包测试与 iPhone 设置页编译，并继续检查 Agent 接入。
- 本轮没有使用用户的真实密钥验证付费服务成功请求，也没有安装手机或手表。配置页的“测试搜索与读取”用于用户配置后的实际验证。
- 保存即启用回归：独立包 10 项测试通过，包含三家服务首次保存、旧配置重新保存、保留已有选择、保存失败、停用与取消。网络响应由本地测试夹具提供，此结果不代表用户手机上的真实接口可用性。
- `check-web-settings.sh` 的 iPhone SDK 模块编译和设置页类型检查通过。

设置页复用 `SettingsView.swift`、`SystemContextSettingsView.swift`、`BrandPalette.swift` 与 `PhoneTypography.swift` 的原生分组、系统字体和中性色；本次新增设置结构，没有复制其他品牌的视觉组件。

2026-10-19 后续：移除独立的「联网服务」页面和设置首页入口，联网控件与 onboarding 共用单页。API Key 配置原地展开，不进入服务管理子页；具体改动和验证边界见[统一连接管理](unified-web-connections-20261019.md)。
