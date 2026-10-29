# iPhone v8 实际界面证据

这 17 张 PNG 是从专用 iPhone 17 Pro / iOS 27 模拟器、实际 UIKit/SwiftUI 页面或 WKWebView 导出的原始图片，未经重画、裁切或修改。每张图的来源路径、大小与 SHA-256 见 [evidence-index.json](evidence-index.json)。测试图中的聊天文字、服务名称和录音来自隔离夹具，不是用户私人资料；最终 Release 首页无夹具注入。

本目录同时保留旧版历史画面和合并 main 后的新画面。**最终首页见 [Release01 实际启动截图](home-release01.png)**；build13 / UI06 的两张图另验证标题内的真实状态展示与点击。build09 的独立状态横幅布局属于历史。原日志和 xcresult 留在被忽略的 `tmp_agent_output/iphone-v8-20261015/`，本目录不复制原始日志、凭据、请求内容或音频。

| 最新实际画面 | 构建 / 轮次 | 已验证范围 |
| --- | --- | --- |
| [最终 Release 首页](home-release01.png) | Release01 | 最终源码新目录构建、19/19 静态检查后实际安装，无测试参数启动；首页显示等待手表状态，没有伪造录音。手机与嵌入 Watch 的四个安装文件 hash 一致。 |
| [新首页与导航栏状态](home-navigation-status-build13.png) | build13 / UI06 | 状态位于原生导航标题内，没有独立横幅；首页、侧栏、搜索、新聊天和草稿保留旅程通过。 |
| [导航栏中的录音状态](home-recording-status-build13.png) | build13 / UI06 | 标题明确显示“手表正在录音”，真实按钮可点击并进入资料；测试同时断言按钮在导航栏边界内。 |
| [AX5 静音状态卡](watch-status-muted-ax5-build13.png) | build13 / UI06 | 最大辅助字号下，从首页状态入口进入资料后的实际卡片；这张是资料页，不是 AX5 首页。 |
| [过期状态卡](watch-status-stale-build13.png) | build13 / UI06 | 已过期状态明确显示“手表状态待更新”，没有继续宣称正在录音。 |

这四张均来自通过的对应 UI 用例，已逐张查看。录音、静音和过期状态由隔离测试夹具注入，证明正式页面的状态展示与导航，**不能代替真实 Watch 采集或 WatchConnectivity 验收**。build13 的 420 个输入在构建前后未变，39 个 Web 资源与源文件一致。UI06 全轮是 **7/8**：唯一失败为自定义服务的 HTTPS 拒绝已正确显示，但系统“保存密码？”提示遮挡返回；失败证据保留，不能写成本轮全部通过或 Release 已通过。

合并 main 后各轮结果分别记录：hosted03 **65/67**；UI04 **7/9**；音频清理与 WK 修复后的 hosted04 **25/25**（仅音频18项和 WK7项）；UI05 **8/14**；UI06 **7/8**。后续 UIKit token 候选的 hosted05–07 各 **0/1**，候选及专用测试已撤回。最终原生 SecureField 的 UI07 **2/2 通过**：实际拒绝可选系统保存提示后，HTTPS 错误、未保存状态、返回及精确草稿保持正确。它们不是同一轮，不能相加为完整通过数。

Release01 的构建、静态检查、资源/许可和安装哈希另记录于 [validation-summary.json](validation-summary.json)，检查器自检本轮 **17/17**。完整验证边界见 [实施记录](../../iphone-v8-20261015.md)。

下表是保留的 **build09 / build10 历史截图**，用于比较旧布局及定位以前的失败；不能替代上面的当前首页。

| 实际画面 | 构建 / 轮次 | 能证明的范围与限制 |
| --- | --- | --- |
| [空聊天首页](home-empty-build09.png) | build09 / UI02 | 默认字号下的首页布局和光学位置。所属侧栏旅程后来失败，不代表该整条旅程通过。 |
| [侧栏](sidebar-build09.png) | build09 / UI02 | 打开后的侧栏外观；该轮随后“新聊天”不可点击。build10 的点击已推进，但又暴露未配置 API 时无法建立空聊天的问题。 |
| [多行输入与软件键盘](composer-keyboard-default-build09.png) | build09 / UI02 | 默认字号、真实屏幕键盘和可点击发送按钮；对应导航、草稿保留和继续编辑用例通过。 |
| [最大辅助字号与软件键盘](composer-keyboard-ax5-build09.png) | build09 / UI02 | AX5 下输入区与真实屏幕键盘；原测试要求键盘可见高度大于 100pt、发送按钮可点，并验证导航后草稿完整。 |
| [真实 seek 后暂停](player-paused-after-seek-build09.png) | build09 / UI02 | 正式 AVAudioPlayer 的暂停、定位、续播后再暂停。夹具用公开语音加 PCM 静音延长操作时间，波形按真实输入显示。 |
| [关闭迷你播放器后资料仍在](library-after-player-close-build09.png) | build09 / UI02 | 迷你播放器已关闭，录音和转写仍保留。此图没有显示正在工作的迷你播放器；开关、暂停/续播和返回详情由对应通过的 UI 用例断言。 |
| [本地真实转写和逐段回听入口](recording-real-transcript-build09.png) | build09 / UI02 | 正式本地 ASR 的原始结果与播放器界面。图中仍有“开饭时间”的已知识别错误，不能当作中文语义质量通过；该旅程的重启、引用移除和删除验证通过。 |
| [服务设置浅色](provider-controlled-light-build09.png) | build09 / hosted02 | 实际 UIHostingController 渲染，显示已保存的合成服务与模型。 |
| [服务设置深色](provider-controlled-dark-build09.png) | build09 / hosted02 | 同一受控连接的深色外观。 |
| [服务设置 AX5](provider-controlled-ax5-build09.png) | build09 / hosted02 | 最大辅助字号的当前视口，较低内容需滚动；只证明截图范围及服务/模型名称实际渲染，不等于整页 VoiceOver 验收。 |
| [上游代码头像浅色](avatar-upstream-light-build10.png) | build10 / chat03 | 实际本地 WKWebView 渲染的新头像，与原始上游代码整合对应。 |
| [上游代码头像深色](avatar-upstream-dark-build10.png) | build10 / chat03 | 同一头像的深色外观；没有采用先前手绘 SVG 版本的截图。 |

Provider 三图使用正式 Pi 编码与 URLSession，在测试 `URLProtocol` 边界返回受控响应，再通过正式验证与保存入口形成页面状态。没有访问公网模型、没有付费请求；图中“已保存”不等于任何真实服务商已认证。验证页面渲染没有再次发起能力探测。头像的动画、停止、Reduce Motion 和受控页面可见性由相应测试验证；静态图片本身不能证明动画，也不等于真机后台行为。

上述历史轮次结果分别为：hosted02 **61/61**；UI02 **12/14**，两项失败完整保留；chat03 **6/6**；UI03 **0/2**。这些轮次不累加成“全部通过”：UI03 的侧栏点击已成功，失败发生于随后缺少 API 配置的新聊天创建；Provider 用例则在 URL 替换前置断言失败，未走到返回页按钮验证。两处后续修补和 main 合并后的验证另记新轮次。

截图整理保留各轮原图；最后的 Release 安装与启动单独记录。设备采集、WatchConnectivity、真实 API 质量以及完整 v0.1 发布验收不在这组截图的结论范围内。
