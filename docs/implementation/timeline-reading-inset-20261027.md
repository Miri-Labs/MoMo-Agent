# 转录列表恢复阅读位置时向左偏移

## 原因与复现

基线 `263a56ca` 已包含 10 月 23 日的日期分页修复，但用户在单条转录及历史列表仍看到圆点贴近屏幕左侧。那次修复移除了外层 `ScrollViewReader`，没有覆盖内层列表在录音重新分组后的定位。

补到的音频可以改变已有时段的起点与 `TimelineWindowID`。`TimelineModel` 保存旧、新 ID 的映射，`TimelineDayPage` 随后调用 `reading.position.scrollTo(id: replacement)` 恢复阅读位置。原先 24pt 水平 padding 位于纵向 ScrollView 的内容内部，滚动目标起点也位于 x=24；这条按 ID 恢复的路径把 `UIScrollView.contentOffset.x` 从 0 变成 24，恰好抵消页面留白。

回归测试使用真实 Archive 收件和重新分组，在手机 TabView 中分别加载 1、3、12 条时段；其中 3、12 条为历史日期。先补入更早日期，再给当前时段补入早 30/60 秒的音频，确认旧 ID 实际映射到新 ID，然后测量滚动偏移。**修改前三个场景均失败，两次重分组共六次测得 x=24，预期为 0。** 这与条数无关，普通静态列表测试不能覆盖该触发条件。

## 修改

- 将水平 24pt 留白移到每天的纵向 ScrollView 外部。内容与滚动目标从 x=0 开始，按 ID 定位不再把页面留白滚走。
- 保留日期左右分页、时段 ID 映射、上下阅读位置、初次定位最新时段、刷新、标记和详情入口。
- 补充真实重分组、历史长短列表、切标签返回的回归测试及截图。
- 界面测试通过当前欢迎页和“稍后配对”进入转录，移除对已失效的首次使用开关的依赖。
- OCR 只检查“19:00”仍可见。边距由真实滚动坐标和界面元素 frame 检查；字形识别框会随识别模型变化，不能作为精确布局坐标。

## 验证

验证工具：Xcode 27.0 / iOS 27.0 Simulator，默认字号。仅使用合成录音，不读取或改变用户录音、聊天、配对及 Mac 服务；没有安装到物理手机。

修改前：`regroup-before.log` / `regroup-before.xcresult`，3 项测试、6 处横向偏移断言失败。

修改后：

- `final.log` / `final.xcresult`：18 项 `TimelineDateNavigationTests` 全部通过。1、3、12 条时段各重分组两次，六次 `TIMELINE_REGROUP` 均记录 `offsetX=0.0`；同时确认旧 ID 的替代项真实存在于新列表，不能以未触发重分组冒充通过。
- `fixed.log` / `fixed.xcresult`：3 项完整界面旅程全部通过，覆盖首次进入、刷新、手动阅读、日期左右滑动与按钮、历史日期、详情返回、日期选择器和切标签返回；实际行两侧保持 24pt 留白。该批集成测试的中间样本混用了时区，重分组前置断言失败，已修正为与原始录音相同的时区并在上述 `final.xcresult` 重新验证；不计为通过证据。
- 已人工查看界面旅程截图及最终重分组截图，确认历史列表圆点与正文保留正常边距。
- SwiftUI 静态检查：0 项 high；5 项既存 medium（搜索防抖、44pt 按钮尺寸与分页 GeometryReader），本次未新增。`git diff --check` 通过。

本次为标准 SwiftUI 布局修复，未增加动画、权限或网络行为；未做辅助功能全矩阵及 Instruments 性能评分，不据此宣称完成全面 UI 质量认证。

证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/timeline-inset-20261027/`。

主要验证命令（构建缓存独立，完整参数见证据日志首行）：

```sh
xcodebuild test -project MoMoAgent.xcodeproj -scheme MoMoAgent \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=9AE9C811-BD01-46AD-875E-8F2DD444E09F' \
  -derivedDataPath /tmp/momo-timeline-inset-20261027 \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:MoMoAgentIntegrationTests/TimelineDateNavigationTests \
  CODE_SIGNING_ALLOWED=NO
```

界面旅程另外覆盖进入/刷新、左右切日期、日期按钮、日期选择器、详情返回与聊天/转录切换。实机当前版本的最终展示仍需安装新构建后验收，源码合并不等于手机已更新。
