# Pebble 品牌字标

2026-10-27 更新：产品字标已改为 **MoMo Agent**，保留 MoMo 的 Pebble 轮廓，并增加圆体 Agent 字形；角色昵称仍为 MoMo。新版不再使用原 MoMoAgent 的 `y` 下沉补偿。当前资源、来源与验证见[MoMo Agent 品牌](brand/momo-agent.md)。下文保留为历史设计与验证记录。

采用用户在 2026-10-19 确认的鹅卵石圆体视觉稿，将 `MoMoAgent` 和 `MoMo` 的完整字形转换成 SVG 轮廓。两份字标用于品牌名称，正文与操作文字继续使用系统字体。资源不依赖外部字体、网络或运行时描摹。

## 使用位置

| 位置 | 字标 | 排版基准 |
| --- | --- | --- |
| 欢迎页、聊天侧栏 | MoMoAgent | 18 点，随正文 Dynamic Type 缩放 |
| 首页头像名称 | MoMo | 16 点 |
| 对话顶部头像名称 | MoMo | 12 点 |

头像名称位于固定高度的布局槽，缩放上限为 `xxxLarge`。字标按比例缩放，保留原生 Text 的布局、可访问名称和 `personalAgent.name` 标识。SVG 覆盖层不参与点击或可访问性树。

`MoMoAgent` 的 `y` 有下伸部分，外框居中时文字重心仍偏上。按用户截图测量，图标与字标外框中心均为 40.5 px，字标笔画重心为 37.75 px。按用户进一步下移的反馈，字标绘制向下偏移字号的 7.5%（18 点时为 1.35 点）；字号、间距和 MoMo 字标不变。

实现位于 `PhoneBrandIcon.swift` 的 `PhoneBrandWordmark`。资源位于 iPhone 的 `Assets.xcassets/PhoneWordmark.imageset` 与 `MoMoWordmark.imageset`，合计 22,200 字节。两者均启用矢量保留及 template 渲染，并使用 `MoMoPalette.ink` 适配深浅色。已有图标和头像保持原样。

## 来源与验证

原稿为本次对话中经用户确认的 imagegen 作品 `exec-3716171a-9711-4f3e-83e9-3ae295ac62d3.png`，SHA-256 为 `850a4eb1f9a1d4e450adf5aca585aa99b5d685eeca21cfe116317690cd23fa35`。使用 VTracer 0.6.12 将两组字形转为贝塞尔轮廓，保留字形及字距；生产资源中没有位图、文本节点或字体引用。

已验证 iOS 18 目标下品牌组件的类型检查、三个调用页面的语法解析、iPhone asset catalog 编译，以及使用实际组件和资源生成的 macOS SwiftUI 深浅色、320/393 点宽预览。预览位于本次工作区的 `tmp_agent_output/20261019-pebble-wordmark/`。

视觉对齐修正后重新检查 iOS 组件类型和 3 倍原生渲染；图标位置、横向间距及整体尺寸保持一致。最终下移效果和测量记录分别为 `alignment-final.png`、`alignment-final-measurements.json`。

本次按项目规则只以默认字号验收；macOS 组件预览不等于 iOS UI 自动化或真机安装。本地未执行完整 App 构建。

## iPhone 验证补充（2026-10-19）

基于 main `f1bddc0` 的矢量实现，在 Xcode 27、iPhone 17 Pro / iOS 27 专用模拟器上完成 App UI 调试构建和以下既有回归，均通过：

- `PhoneHomeSuggestionJourneyTests/testCardsSendDirectlyToAgentAndTypingHidesSuggestions`：首页到会话顶部的同一个 MoMo、原生文字访问标识及输入交互。
- `PhoneNavigationTests/testDrawerSearchAndNewConversationKeepDraft`：MoMoAgent 侧栏字标、搜索、创建会话与草稿保留。

结果包：`/tmp/momo-pebble-main-native-ui.xcresult`；导出原始截图：`/tmp/momo-pebble-main-native-screens/`。另以原生截图核对深色首页和首次体验：`/tmp/momo-pebble-main-home-dark-ready.png`、`/tmp/momo-pebble-main-welcome-dark.png`。仅按默认字号检查；字标完整、可读，图标、Avatar 与正文未更换。

本机未准备 CoreML 资源，UI 调试构建排除了对应资源复制项，未执行发布包、ASR 或真机安装验收。通过现有版本检查器的 `configured_version` 核对调试产物，iPhone、内嵌 Watch 和 Widget 均与共享配置 `1.10.8` 一致。字形扫描未报告问题；未新增视图状态或交互逻辑。
