# 手机聊天录音引用

2026-10-28，基于 `dc35d0d7`，任务分支 `codex/source-links-20261028`。

## 原因与修复

- 共用 WebKit 渲染器的 Markdown 默认不识别裸 `momoagent://source/…`。增加限定录音引用的 inline tokenizer，显示下划线「查看录音」。已有历史回复无需修改存储内容，重新渲染即可生效。Markdown 已有的有意义标题保留；自动链接和以 URL 为标题的链接也缩短。代码块和行内代码仍按原样展示。
- 手机路由原来依赖 `PhoneContextSync.sources` 中的最新版本，导致尚未同步、离线或录音追加后的旧引用在到达档案校验前被拒绝。现在解析完整的 session/span/version/generation，再由现有 `SourceExcerptView` 和 `ArchiveStore.validateSources` 校验并读取。未改的历史片段仍可读和回听；修改、删除、虚构片段或无效版本不会被替换为其他内容。
- 保留 URI 兼容标识，不改名、不迁移消息、不改配对协议。未放宽 WebKit 的远程资源策略和 URI 白名单。既有气泡、增量 Markdown 节点和回执状态保持原位更新。

本次范围是截图中的手机聊天引用及共享 WebKit 展示；没有改造 Mac 原生录音导航、模型执行、连接或 Codex 客户端。

## 实际验证

在此 worktree 执行：

```sh
node Tests/Support/chat-renderer-core.test.cjs
node Tests/Support/chat-localization.test.cjs
uv run --no-project python Tests/Support/sync-chat-localization.py
swift Tests/Support/chat-source-links-smoke.swift tmp_agent_output/source-links
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgentThroughput \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=BD497CC1-54F1-4141-AFA7-13CB9C532652' \
  -derivedDataPath tmp_agent_output/source-links/DerivedData \
  -resultBundlePath tmp_agent_output/source-links/SourceLinks.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:MoMoAgentIntegrationTests/MarkdownReadingTests \
  -only-testing:MoMoAgentIntegrationTests/ChatRendererTests/testBareRecordingCitationsAreCompactClickableAndStableAfterHistoryRefresh \
  -only-testing:MoMoAgentIntegrationTests/ChatRendererTests/testStreamingKeepsStableDOMAndFinishesWithoutDuplicateText \
  CODE_SIGNING_ALLOWED=NO test
```

结果：

- 25 项 Node 渲染规则测试通过；四语言标签及生成字典一致性检查通过。
- 真实 macOS WKWebView：裸地址、Markdown 标题、自动链接、行内代码、亮/暗/英文、完整点击回调通过；20 次历史刷新保持同一链接和气泡 DOM 节点。
- Xcode 27 / iOS 27 / 独立 iPhone 17 模拟器：12 项测试通过。包括真实 iOS WebKit 回调、流式文本稳定性、URL 校验，以及创建临时录音档案后验证追加后的历史引用、音频租约、虚构片段、修改和删除。全部使用合成测试数据，没有读取或修改用户录音。
- SwiftUI 静态扫描：0 high、1 medium。该 medium 来自既有 `ForEach(Array(sources.enumerated()), id: \.element.citationURL)`，实际 identity 是 citationURL，不是数组下标；未改无关代码。
- 已人工查看实际 iOS WebKit 亮/暗截图，短链接可读，原文标题保留。测试截图包含多个等价引用格式，用于验证，不表示产品重复追加来源列表。

证据保存在 `/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/source-links-20261028/`。完整日志、xcresult、导出的截图与本轮 Git diff 均保留。测试完成后删除本轮 DerivedData、临时资源链接及专用模拟器；只保留小型验证证据。

## 交付边界

首次代码验证只在本地完成；随后用户明确要求提交、合并和部署，交付版本为 1.39.4。实际构建、合并、安装和启动结果分别记录在交付目录的 `DELIVERY.md`，未获得设备回执的项目不记为通过。真实手机点击用户截图中的引用仍需单独确认。Codex 原会话的 HTTP 400 是另一个已定位到 Codex 请求接口的问题，本项目改动不声称修复 Codex 服务。

## Mac 原生来源跳转补齐（1.39.5）

用户在 1.39.4 点击 Mac 聊天引用后，Launch Services 弹出“未设定用来打开 URL 的应用程序”。原因是共享 WebKit 已发送完整 URL，但 DesktopRoot 没有拦截 `openURL`，默认交给系统处理。

DesktopRoot 现在将录音 URL 交给原生 sheet，通过现有、带鉴权的 Context API 按 session/span 找到原文；普通网页仍由系统打开。读取支持来源列表和正文分页，不依赖当前转录列表是否加载。未知/删除来源、重复 session、generation 变化、未来版本、缺失片段以及失效分页明确失败，不跳到别的录音。

Mac 副本只保存当前正文。对旧 version 的链接，在 generation 相同且 span 仍存在时显示**当前原文**，并标明录音已有更新；不冒充历史快照。用户截图中的来源由 78 版追加到了 86 版，目标 span 仍存在。手机原生档案仍按历史版本校验，不受此 Mac 展示逻辑影响。

验证：`swift test --package-path Packages/MoMoAgentAgentClient --scratch-path <isolated-cache> --skip-update --filter RecordingCitationTests`，6 项通过，包括原文/来源分页、旧版本标识、无效链接、歧义、缺失来源和版本变更。桌面 Release 构建和实机 UI 点击结果记录在本轮 `outputs/source-links-20261028/DELIVERY.md`。
