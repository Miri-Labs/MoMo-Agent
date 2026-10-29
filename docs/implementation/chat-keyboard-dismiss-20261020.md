# 聊天页下滑收起键盘

基于 main `3364194`。键盘弹出时，用户可以从首页或聊天消息区向下拖动，让键盘随手势收起，保留未发送草稿。

原实现仅在空白首页设置了交互式收键盘。消息 WebView 和临时原生文字视图缺少对应配置；首页按内容大小启用回弹，内容较少时也可能无法拖动。

- WebView 的原生滚动视图使用 `keyboardDismissMode = .interactive`，并允许短对话纵向回弹。
- 临时原生文字视图使用相同的交互式收键盘行为。
- 首页在输入框获得焦点时允许纵向回弹，失去焦点后恢复原有规则。

直接复用系统滚动行为，未添加覆盖文本选择的自定义拖动手势。API 依据：[UIKit keyboardDismissMode](https://developer.apple.com/documentation/uikit/uiscrollview/keyboarddismissmode-swift.property)、[SwiftUI scrollDismissesKeyboard](https://developer.apple.com/documentation/swiftui/view/scrolldismisseskeyboard(_:))。

验证：两个改动文件的 Swift 语法解析和 `git diff --check` 通过。未构建、安装或操作主任务正在测量的手机。真机仍需确认空白首页、短对话、长对话的下滑行为，以及收起后草稿保留、重新点击输入框和消息阅读位置。
