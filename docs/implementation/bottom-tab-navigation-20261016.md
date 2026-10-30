# 聊天与转录底部导航

2026-10-16 用户要求将转录作为一级功能，与聊天并列放在底部：左聊天，右转录。本轮基于远端 main `dd703be`，任务分支为 `codex/bottom-tab-navigation`。

## 导航与状态

- 使用 SwiftUI 原生 `TabView` 和两个 `Tab`，各自包含 `NavigationStack`。转录首页移除原先从聊天进入的返回层级。
- 聊天侧栏移除转录行，保留聊天搜索、历史、新聊天与设置。
- 聊天顶部手表状态及输入框加号切换到转录标签。它们不再将转录压入聊天导航栈。
- 切换标签保留聊天草稿、转录日期、搜索、详情与既有播放状态。离开聊天时解除输入焦点。
- 从录音或时间段发起讨论，继续通过会话协调器校验并设置来源；成功后清空聊天的次级页面并选择聊天标签，转录详情保留。
- 接收、转写、Agent 请求和播放仍归 `PhoneRuntime` 及其协调器管理，不随标签切换重建。
- 欢迎页完成后才进入双标签首页。未配置模型也可使用转录。
- 全局状态提示放在页面上方，给底栏保留完整的可见和点击区域。
- 录音及时间段详情的讨论按钮使用独立容器，背景不延伸到系统安全区，点击与可访问性范围落在可见按钮内。

## 参考

实际查看 `landing-screens/native-home.png`、`docs/implementation/evidence/2026-10-15-transcript-timeline/phone-yesterday.png`、HANDOFF 和最新根导航代码，沿用系统字体、中性黑白、Avatar 与手表点阵卡。底部双入口为本轮用户确认的新导航，不沿用旧设计中转录从属于聊天的层级。

平台行为按 [Apple Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) 与 [SwiftUI TabView](https://developer.apple.com/documentation/swiftui/tabview) 核对：标签承载一级功能，包含图标和文字，各自保留导航状态。使用既有 iOS 18 最低版本支持的 `Tab` API，不新增依赖。

## 验证

验证使用系统默认字号和一台 iPhone 18 Pro / iOS 27 模拟器。

- 最终 `build-for-testing` 通过，使用 ad-hoc 签名。iPhone 与内嵌 Watch 目标完成编译。
- 浅色 UI 回归 **11 通过、0 失败、0 跳过**。覆盖底栏左右顺序、Avatar 实际像素、草稿与键盘、聊天侧栏、首次体验与重启、无模型访问、日期选择、详情与回听、来源回聊天、状态提示和生成中切换标签。
- 用 `simctl ui … appearance dark` 切换模拟器系统外观后，双标签完整旅程再次通过，**1 通过、0 失败**。实际查看深色[聊天](evidence/2026-10-16-bottom-tabs/chat-dark.png)与[转录](evidence/2026-10-16-bottom-tabs/transcripts-dark.png)截图，确认背景、文字、Avatar 与原生底栏均已切到深色。
- 生成中切换使用既有受控 SSE，经真实 App/Pi/URLSession/原生消息区运行；时间线 UI 使用固定转录和音频资料。本轮验证导航与状态，不计作外部模型或 ASR 质量验收。
- 首轮 7 通过、4 失败。详情按钮的可访问性范围延伸到 Tab Bar，自动点击落在可见按钮外；全局底部提示覆盖底栏。修正容器和安全区后，相关用例通过。另一个失败来自启动同步错过首次体验短片段，改为自动化就绪后点原有重播入口，再检查三段内容。
- 已检查真实浅色截图中的首页、转录、聊天历史、详情按钮与状态提示。Pen 的 N00–N03 使用本轮原生截图，不以旧截图或示意图代表实际布局。
- `git diff --check` 通过；两份 Pen 均可解析，新增画板引用的三张原生截图存在，既有画板保持原值。

浅色截图：[聊天](evidence/2026-10-16-bottom-tabs/chat-light.png)、[转录](evidence/2026-10-16-bottom-tabs/transcripts-light.png)、[聊天历史](evidence/2026-10-16-bottom-tabs/chat-history.png)、[引用回聊天](evidence/2026-10-16-bottom-tabs/transcript-to-chat.png)、[上方状态提示](evidence/2026-10-16-bottom-tabs/status-banner.png)。来源及 SHA-256 见同目录 `screenshots.json`。

本机完整日志和 xcresult：`/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261016-momoagent-bottom-tabs/`。主回归为 `navigation-final.xcresult`，真实系统深色为 `navigation-dark.xcresult`，修正后构建为 `build-repair.log`；后续只改测试截图命名、移除无效的外观启动参数，对应 `build-evidence.log`。启动参数未改变系统外观，因此旧附件里名称包含 `dark` 的截图仍为浅色，不用作深色证据。

本轮没有更新物理 iPhone 或 Watch 的安装包。
