# Android 全量对齐实施记录

日期：2026-11-12。方案见 [Android 对齐 iPhone App 方案](../plan/android-parity.md)，待办见 [Android 全量对齐待办](../todos/android-parity.md)。

## 结果

| 检查 | 结果 |
| --- | --- |
| Android `:app:assembleDebug` | 通过，APK 42 MB，`com.momoagent.android` 0.2.2（versionCode 4），minSdk 26，targetSdk 35 |
| Android `:app:testDebugUnitTest` | 24/24 通过（配对码、LAN 指纹、固定证书、SSE、消息体） |
| Mac 设备自吊销 | 临时设备配对→批准→`POST /pair/revoke` 返回 200，状态变为 revoked；用户已批准设备不受影响 |
| Android `:app:lintDebug` | 0 error，30 warning（版本升级提示、`allowBackup`、未使用资源等） |
| APK SHA-256 | `b1687bd269602e724b3fead9ce6ee1a0da06cc33702a0f46b2e4af2e9c6c6860` |
| Mac App 构建 | 通过：本地占位 Sherpa 包仅用于 SwiftPM 解析；Mac target 不链接 `MoMoSpeech`；真实运行时复制自现有 App |
| Mac App 启动 | 通过：运行时补丁后 PID 55322，版本 0.5.8，LAN 自动恢复 |
| Mac LAN 端到端 | 通过：`https://10.1.20.155:8769`、证书指纹、配对、批准、快照 200 |
| Android 真机/模拟器 | **未执行**：本机没有可用设备或模拟器镜像 |

## 交付物

- Android：`~/Desktop/MoMoAgent-android-0.3.1-liquid-glass.apk`（versionCode 6，
  versionName 0.3.1，SHA-256 `1f0924eb5844fd3ed411573031316138e543c8b91a152ac04985f24cfae57999`）；
  0.3.0 及更早的安装包已清理，测试与 lint 摘要保留在 `tmp_agent_output/android/`。
- Mac：`~/Desktop/MoMo-Agent-Mac-Apple-Silicon-0.5.8-lan.zip`；当前运行的 App 在
  `~/Library/Developer/Xcode/DerivedData/MoMoAgent-dotzbwgmsxfosuadtdtcspkxwvlm/Build/Products/Debug/MoMo Agent.app`

## 实现内容

- Welcome → Connection → 聊天/转录/记忆 Tab → 设置；欢迎文案与 iPhone 的三段场景一致。
- 配对：扫码、数字核对、待配对持久化与前台恢复、2 秒轮询、Tailscale 瞬时重试、LAN 指纹固定；手动配置在设置中。
- 聊天：复用 iPhone 的 `Rendering/Web` 渲染器（Markdown、工具、附件、已送达/已读、三点等待），Kotlin 生成同样的 `ChatRenderSnapshot` 字段。
- 状态机：快照 + `subscribe` SSE、游标/心跳/重连、乐观消息、幂等 operation ID、服务端回显去重、运行事件流。
- 输入区：玻璃胶囊输入表面、图片/文本附件、发送、附件预览；不显示自制任务按钮。
- 品牌：角色 WebView（同一 `agent-avatar.html`/`momoagent-avatar.js`）、Pebble 字标、iPhone 品牌图标、启动图标。
- 转录/记忆：只读读取 Mac context API；明确标注“来自已配对的 Mac”，不伪造本地转录。
- 设置：连接状态、重连、重新配对、手动配置、网络路线/地址、版本、解除配对。
- 深色模式按 iPhone 的四色明暗值。

## 构建说明

Mac App 的 SwiftPM 仍要求 Sherpa 二进制目标存在，但 Mac target 不链接 `MoMoSpeech`（`ClientControls.swift` 在 macOS 分支不导入它）。本轮用本地占位 xcframework 满足解析，占位不进入 Mac App，也没有提交到仓库；真实 `AgentRuntime` 从现有 App 复制，Access Python 文件使用本仓库的 LAN 版本。该做法只用于本机验证，正式构建仍需私有运行库。

## 本轮修复

- 手机端解除配对现在先调用 `POST /pair/revoke`，Mac 用设备自己的 bearer 凭据吊销对应授权；只有 Mac 确认后才清除本地连接。Mac 界面“已配对设备”随之移除。
- Mac access 服务启动时检查是否存在已批准的 LAN 设备，存在则自动启动 LAN 监听；App 重启后已配对的 Android 设备无需重新扫码。
- 聊天/欢迎/连接页的角色增加 `MoMoStill` 静态回退；WebView 确认 `svg.life-avatar path` 存在后才隐藏回退，避免角色区域空白。
- 设置、欢迎和连接页增加状态栏/导航栏内边距；设置页去掉重复的“Android 预览”版本值，解除配对归入“数据”分组；解除失败时保留连接并显示原因。
- 品牌 SVG 改为预渲染 PNG（`phone_wordmark.png`、`momo_wordmark.png`、`momo_still.png`），修复 AndroidSVG 把 “MoMo Agent” 截成 “MoMo Aae” 以及 `MoMoStill` 空白的问题；静态角色始终绘制在动态 WebView 角色下方。
- 配对等待页的副标题改为“确认 Mac 显示相同数字，再在 Mac 点击允许连接”，不再重复标题“核对两端的数字”。
- 键盘弹出时隐藏底部 Tab 栏，使输入框贴合键盘，消除输入框与键盘之间的空白带。

## 液态玻璃外观（0.3.0）

参考用户提供的 7.5 秒 iPhone 录屏（`0e714a732e1a802e4056a3a4649c28c9.mp4`），只改视觉层，不改协议、状态机与数据。

- 新增 `ui/Glass.kt`：半透明渐变、顶部高光、白色细边、柔和环境阴影；按压缩放使用弹簧动画并增强高光。`GlassDialog`、`GlassTabBar`、`GlassTasksButton`、`GlassIconButton` 统一复用。
- 新增 `ui/LiquidBackdrop.kt`：接近中性的低对比环境底色，避免玻璃控件失去亮度。欢迎、连接、聊天、转录、记忆、设置页均使用同一底色。
- 聊天改为浮层结构：WebView 铺满，角色/字标与左设置、右任务/桌面按钮固定在顶部，内容从下方滚过；输入区悬浮在底部。`ChatRenderSnapshot.appearance.headerInset` 传入状态栏加头部高度，聊天页顶部留出对应间距；Android 聊天页额外声明透明背景与 152px 底部留白，供悬浮输入区使用。
- 玻璃控件覆盖：顶部圆形按钮、任务胶囊（有任务时显示计数）、桌面按钮、悬浮 Tab 胶囊、输入胶囊与发送/语音/加号、聊天连接状态浮层（替代视频里的手表状态浮层，Android 无手表，因此显示 Mac 连接状态与路线）、加载/错误横幅、连接/记忆/转录页头部、记忆搜索、记忆/转录卡片、设置分组和弹窗。
- 聊天气泡、附件卡片和转录/记忆正文保持实色，贴近参考视频；液态玻璃只用于控件与浮层。
- 角色右下角新增小玻璃状态点：绿色已连接、黄色连接中/重连中、红色需要重新配对或不可用；点击展开玻璃浮层，提供连接设置入口。该状态是 Mac 链路状态，不冒充手表录音状态。
- 任务、桌面、语音、附件、记忆详情、解除配对等弹窗统一改为玻璃卡片；麦克风入口明确提示 Android 语音输入尚未接入，避免假功能。
- 已知限制：Compose 没有 `backdrop-filter`。当前用低对比背景、半透明渐变和控件下方渐隐遮罩近似，而不是真实模糊控件背后的内容；和视频的折射/模糊仍有差异，已在 Android README 的 Liquid glass 一节记录。

### 0.3.1 版本显示修复

- 设置页原先把版本读成 `PackageManager.getPackageInfo(...).versionName ?: "0.1.0"`，读取失败或运行旧包时就会一直显示 0.1.0。现在启用 `buildConfig`，版本直接读取编译期 `BuildConfig.VERSION_NAME`，不再有 0.1.0 兜底。
- 设置页标题下方和“关于”分组都显示版本；欢迎页与连接页底部也显示 `MoMo Agent 0.3.1`，便于安装后立刻确认运行的是哪个包。
- APK 清单已核对：`android:versionName="0.3.1"`、`android:versionCode="6"`、包名 `com.momoagent.android`。
- 如果手机安装后仍显示 0.1.0，说明旧的安装包没有被替换（常见于签名不一致或安装器未覆盖）。需要先卸载旧版再安装新包；本机配对凭据会随卸载清除，重新扫码配对即可。

## 未完成

- Android 本地录音、端上 ASR、声纹/分段与本地转录页。
- 手表/耳机采集状态、桌面控制、生活插画、Dream 简报卡片。
- 聊天语音输入、推送、Relay、iOS LAN 客户端。
- 真机扫码/批准/流式回复、断线重连和后台行为的端到端验证。
- 正式版网络策略：目前只有 debug 允许 Tailscale 系统 VPN 的明文；发布前必须收紧。
