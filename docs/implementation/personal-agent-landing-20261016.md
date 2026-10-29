# Personal Agent 首次体验实施

2026-10-16。设计源为 [Landing](../design/iphone-review-20261015/LANDING.md) 与其中 L01–L11；用户明确授权原生代码落地 main。

## 最终行为

首次体验演三段：既定旅行、会议后的方案跟进、妈妈生日。每段先有生活上下文，再有一句省略背景的请求，最后让用户看到继承了什么。重点是跨来源持续理解；不把审批或交回控制作为主张。背景包含生活声音、会议、邮件、项目资料、关系与长期偏好。

`PhoneWelcomeView` 管理只读演示与可取消的播放时钟。三段完整结束才显示开始；重播清空完成门槛。VoiceOver 逐幕手动继续，减少动态效果取消跳跃；大字号保持滚动与可达按钮。离开前台取消当前计时，返回后留足本幕阅读时间。场景不会写入 ArchiveStore、Agent 消息或记忆。

`PhoneRootView` 在导航内容的固定 ZStack 上承载一个 Avatar overlay，页面只提供位置锚点。具体容器避免 Group 将 modifier 分配到条件分支而重建 WebKit 视图。Avatar 使用固定 280pt 离线画布，原生 scale / position 和单次关键帧控制缩放、腾空、落地，避免动态修改 WKWebView viewport 引发异步排版。结束进入现有空白聊天首页，头像停在问候语上方，原图标进入顶部栏。无需预先配置服务；录音与转录入口继续可用。

Avatar 重用项目已有 `momoagent-avatar.js` 与上游轮廓。新 `Web/agent-avatar.html` 不联网、不接收聊天内容、不注入脚本消息处理器；导航只允许对应本地文件。首页空闲时复用引擎既有的轻微摆动与偶发眨眼；输入、打开侧栏、进入其他页面或离开前台时停止循环，减少动态效果时保持静态。加载失败显示可见占位说明。未增加第三方依赖。

## 验证

工具链为 Xcode 27.0 / iOS 27 / watchOS 27，使用独立 DerivedData。以 `/tmp` 为 DerivedData 时依赖解包因 macOS 符号链接路径校验失败；改为标准 Library 路径后正常，不修改依赖或工具链。

- iPhone 构建通过。
- `PhoneNavigationTests/testFirstUseFinishesThreeContextsBeforeEnteringHome`：三段顺序、提前入口不存在、结束可进入、顶部状态与菜单可用、本地转录可打开、完成状态跨重启保留。
- `testFirstUseReplayClosesEntryUntilAllContextsFinishAgain`：辅助功能最大字号下按钮可达，重播重新关闭入口。
- `testDrawerSearchAndNewConversationKeepDraft`：首页光学位置、抽屉搜索、新聊天及未发送草稿保留。
- `testComposerRemainsReachableWithLargeTextAndKeyboard`：大字号、软件键盘下编辑与导航回程可达。
- Watch `testRecordMarkPauseRelaunchResumeStopAndKeepPendingAudio`：实际模拟器录制、标记、静音、重启恢复、结束与待传原音保留，通过。
- 浏览器完整三段、重播、提前进入拒绝、单一 Avatar、深色、320px 减少动态效果和公网 HTTPS 体验通过。原型源码及检查记录放在 [landing-motion](../design/iphone-review-20261015/landing-motion/)。

原生截图：[首页](../design/iphone-review-20261015/landing-screens/native-home.png)、[工作场景](../design/iphone-review-20261015/landing-screens/native-work.png)、[家人场景](../design/iphone-review-20261015/landing-screens/native-family.png)、[结束态](../design/iphone-review-20261015/landing-screens/native-ready.png)、[Watch 录制中](../design/iphone-review-20261015/landing-screens/native-watch-recording.png)。

本轮不宣称完成全天候录音、邮件/日程集成、长期跨来源记忆或订票/发邮件等外部执行；这些是演示的终局方向。未进行物理 iPhone / Watch 安装与同步验收，VoiceOver 的实际语音朗读尚待设备验收。

## 首页轻微动效补充

2026-10-16。首页原先将 `PersonalAgentSlot.active` 固定为 false；改为没有输入焦点时启用现有 `listening` 动画，保留原有缓慢转向、微小摆动及偶发眨眼，不新增动画引擎或布局缩放。`PhoneRootView` 增加导航路径为空的限制，进入转录/设置等页面后停止；侧栏、前后台及减少动态效果继续由已有 overlay 和离线页面控制。点击打招呼的单次动作保持原样。采用 standard 的低强度动效。

验证使用 Xcode 27.0、iOS 27.0，目标为 `MoMo v8 393pt acceptance`（`9AE9C811-BD01-46AD-875E-8F2DD444E09F`）：

- 构建并执行两项现有回归，2/2 通过、0 跳过，xcresult 的 runtimeWarnings 为空：`testDrawerSearchAndNewConversationKeepDraft` 检查首页、输入、抽屉及草稿；`testOriginalAvatarFollowsAppearanceAndPausesWhenHiddenOrMotionReduced` 检查实际渲染器的深浅色、减少动态效果和受控可见性事件。后者不冒充实际系统切换或后台测试。
- 上游固定资源构建检查通过，既有 6 项 Avatar 运行时检查通过，涵盖几何更新、眨眼、调度上限、停止与销毁清理。
- 正式首页在隔离 Debug 档案中录制 8 秒。两张 1179 × 2556 设备帧间隔 1.5 秒，头像区域 1534 个像素变化，系统状态栏以外的其他内容区无变化；实际查看确认品牌、手表状态、问候语和输入布局保留。
- 两个修改文件的 SwiftUI 静态扫描无高风险项；14 条中等提示主要是既有固定尺寸、字体和布局检查。单文件扫描未识别的减少动态效果路径实际在 `PersonalAgentOverlay` 与 `agent-avatar.html` 中控制。

日志、xcresult、帧测量与视频在忽略目录 `tmp_agent_output/home-avatar-motion-20261016/`。本次没有新增依赖，没有更改动画资源或 Watch 代码；未做物理设备能耗、Instruments 或 VoiceOver 语音复核，不作帧率或全 App 品质评分承诺。
