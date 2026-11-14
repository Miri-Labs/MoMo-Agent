# Android 对齐 iPhone App 方案

日期：2026-11-12。状态：核心对齐已实现（Android 0.2.0）；真机尚未验证。实施记录见[Android 全量对齐实施记录](../implementation/android-parity-20261112.md)。本方案把 iPhone 端当作产品规格，Android 只做平台适配，不另起一套设计。

## 实现结果（2026-11-12）

| 阶段 | 状态 |
| --- | --- |
| A 壳与品牌 | 已实现：Welcome → Connection → 三 Tab；角色 WebView、Pebble 字标、iPhone 品牌图标；深色/浅色令牌 |
| B 会话正确性 | 已实现：快照 + subscribe SSE、游标/心跳/重连、乐观消息、回执、三点、附件、iPhone Web 渲染器 |
| C 设置与记忆 | 已实现：Mac 连接管理、只读记忆、只读 Mac 转录、设置分组 |
| D 平台适配 | 部分：系统 Tailscale、LAN 证书固定、Keystore、返回键；正式版网络策略待收紧 |
| E 转录 | 未实现：Android 本地录音/端上 ASR 与本地转录页仍是独立切片 |

当前已验证：Android 0.2.2 `assembleDebug` 通过、24/24 单测、lint 0 error；Mac App 在本机构建并启动，LAN 端到端通过，设备自吊销与 LAN 自动恢复已验证。真机/模拟器未验证。

## 1. 原则

- iPhone App 的页面结构、文案、状态、视觉令牌和交互顺序是基准；Android 不自行发明页面、按钮或空状态。
- 保留已经验证的传输层：扫码配对、`network: "lan"` 证书固定、Tailscale 端点兼容、Keystore、HTTPS/SSE 客户端。
- 只对 Android 平台差异做明确适配：相机权限、系统 Tailscale VPN、Keystore、返回键、系统字体、无嵌入 TailscaleKit、无本地录音/ASR。
- 不以假数据或占位页伪装 iPhone 已有能力。Android 暂时没有的（本地转录、桌面控制、耳机/手表状态）不显示假 UI，列入独立切片。

## 2. iPhone 基准与 Android 目标

| iPhone 端 | 作用 | Android 目标 |
| --- | --- | --- |
| `Bootstrap/PhoneRootView.swift` | Welcome → Connection → 聊天/转录/记忆 Tab | 同样的根流程与 Tab 结构 |
| `ClientUI/WelcomeExperienceView.swift` | 10 秒三段式场景 + 角色 | Compose 版欢迎体验，文案与节奏一致 |
| `Features/RemoteAgent/PhoneConnectionFlow.swift` | 连接页、Tailscale 登录、稍后配对 | 同样的连接页与分支 |
| `Features/RemoteAgent/PhonePairingView.swift` | 扫码、数字核对、重试、结束状态 | 同样的配对组件与文案 |
| `Features/RemoteAgent/PhonePairing.swift` | 待配对持久化、断点恢复、2 秒轮询 | Kotlin `PairingRepository`，同样的持久化和恢复 |
| `Features/RemoteAgent/PhoneRemoteAgent.swift` | 连接验证、Keychain、路径恢复 | `RemoteAgentRepository` + Keystore |
| `Packages/MoMoAgentAgentClient/RemoteTaskStore.swift` | 会话状态机、快照/订阅、回执、任务 | Kotlin `ConversationStore`，按同一语义移植 |
| `ClientUI/ChatRenderSnapshot.swift` | Agent 事实 → 渲染器 JSON | Kotlin `ChatRenderSnapshot`，字段一致 |
| `Features/Assistant/Rendering/Web/*` | Markdown/工具/附件渲染器 | Android WebView 复用同一套 HTML/CSS/JS |
| `ClientUI/ChatRendererView.swift` | 用户/助手/系统消息、已读/已送达、三点 | 复用 Web 渲染器 + 原生回执/等待层 |
| `ClientUI/ClientControls.swift` 的 `ClientComposer` | 附件、拍照、语音、发送 | Compose 输入区，先文本/附件，语音后补 |
| `ClientUI/PersonalAgentBrand.swift` | 角色、字标、状态小标 | WebView 角色 + Pebble 字标资源 |
| `Features/RemoteAgent/RemoteMemoryView.swift` | Mac 记忆 Tab | 通过 context API 的只读记忆页 |
| `Features/Settings/PhoneSettingsChrome.swift` | 设置分组/行/表面 | Compose 设置组件，同样的层级 |
| `PhoneRootView` 的 Tab | 聊天/转录/记忆 | 聊天/记忆先做；转录等本地 ASR 切片 |

## 3. 当前 Android 的偏差

| 区域 | 现状 | 处理 |
| --- | --- | --- |
| 首次进入 | 直接配对页 | 改为 Welcome → Connection → 配对 |
| 配对 | 扫码 + 主界面粘贴框 | 主流程只扫码；手动配置移到设置（对齐 iPhone） |
| 配对恢复 | 只保存批准后的连接 | 保存待配对邀请/凭据/请求 ID，重启可恢复 |
| 聊天外壳 | 顶部工具栏 + 简单气泡 | 空态头像 144、会话头像 84、字标、浮动头、无导航栏 |
| 消息渲染 | 纯文本 LazyColumn | iPhone Web 渲染器（Markdown/工具/附件） |
| 回执 | 无 | `已送达 → 已读 → 隐藏`，仅最后一条用户消息下显示 |
| 等待 | 自绘“正在思考”文字 | 3 点胶囊动画，仅在已读后出现 |
| 会话同步 | 发完刷新快照 | 快照 + `subscribe` SSE + 游标/心跳/重连 |
| 输入区 | Material TextField + 图标 | 24pt 圆角输入表面、附件条、拍照/文件、发送 |
| 导航 | 单页聊天 | 聊天/记忆 Tab + 设置 sheet；转录待 ASR |
| 品牌 | 文字 MoMo + 占位图标 | Pebble 字标 + iPhone 角色 WebView + 状态小标 |
| 设置 | 只有解除配对 | Mac 连接、重连/重配、网络路线、手动配置、关于 |
| 状态所有权 | 单个 AppViewModel | PairingRepository / RemoteAgentRepository / ConversationStore |
| 深色模式 | 仅浅色 | 按 iPhone 的四色明暗资源实现 |

## 4. 目标 Android 结构

```text
Apps/AndroidApp/app/src/main/
├── assets/chat/                 # 复用 iPhone Rendering/Web
├── assets/avatar/               # 复用角色 HTML/SVG/JS
├── java/com/momoagent/android/
│   ├── data/
│   │   ├── AgentApi.kt          # 保留并扩展 subscribe/attachments
│   │   ├── PairingCode.kt       # 保留 LAN/Tailscale 校验
│   │   ├── PinnedTls.kt         # 保留
│   │   └── PairingStore.kt      # 凭据 + 待配对状态
│   ├── remote/
│   │   ├── PairingRepository.kt # 对齐 PhonePairing
│   │   ├── RemoteAgentRepository.kt
│   │   ├── ConversationStore.kt # 对齐 RemoteTaskStore
│   │   └── ChatRenderSnapshot.kt
│   └── ui/
│       ├── RootScreen.kt        # Welcome/Connection/MainTabs
│       ├── WelcomeScreen.kt
│       ├── ConnectionFlow.kt
│       ├── PairingControls.kt
│       ├── ChatScreen.kt        # 头像 + Web 渲染器 + 输入区
│       ├── ChatWebView.kt       # assets/chat 桥接
│       ├── MemoryScreen.kt
│       └── SettingsScreen.kt
```

## 5. 分阶段与验收

### 阶段 A：壳与品牌（先交付）

- 设计令牌：iPhone 的 16/22/17/15/14/13/12 字号、行距、四色明暗、24pt 表面、0.75 线、52pt 胶囊主按钮。
- Welcome → Connection → 主界面结构；聊天/记忆 Tab；设置 sheet。
- 聊天空态：角色 144 + Pebble 字标；会话态：角色 84 + 字标 + 浮动头（设置、任务入口后续）。
- 输入区：24pt 圆角、附件条、发送；语音后补。
- 验收：与 iPhone 截图并排，页面层级、文案、间距、空态一致；扫码仍是主配对方式。

### 阶段 B：会话正确性

- 移植 `ConversationStore`：快照 + `subscribe` SSE、事件游标、心跳、重连退避、乐观消息、幂等 operation ID、服务端回显去重。
- 移植回执：`delivered → read → hidden`，只在最后一条用户消息下显示；三点只在已读后出现。
- 渲染：复用 iPhone Web 渲染器；Kotlin 生成同样字段的 `ChatRenderSnapshot`；工具/附件/系统消息同源。
- 输入区补齐照片/文件附件（`AgentAttachment` 契约），发送失败重试；Markdown/引用/代码同 iPhone。
- 验收：双端同时在线，消息顺序、回执、等待、失败重试一致；不出现自制任务按钮。

### 阶段 C：设置与记忆

- Mac 连接页：配对状态、连接状态、重新连接、重新配对、手动配置、网络路线/地址（对齐 `PhoneMacConnectionView`）。
- 记忆 Tab：`/context/v1/memories`、`/source`、`/status` 的只读浏览；卡片操作后续。
- 设置分组/表面/行组件对齐 `PhoneSettingsChrome`；只保留 Android 适用的项，不复制 iOS 专属语音设置。
- 验收：断网/重连/重配、记忆加载与来源回链可用。

### 阶段 D：平台适配与扩展

- 深色模式、返回键、TalkBack、动态字号（默认字号验证）、中文/英文本地化。
- 系统 Tailscale VPN：保留 debug 明文配置的受控策略；正式版必须改为内嵌传输或按 `100.64/10` 的受控网络策略。
- LAN 直连保留，作为 Android 先行的安全扩展；iPhone 端后续补同样的证书固定。
- 启动图标从 MoMo Avatar 源图导出，不用字母 M 或临时圆形脸。

### 阶段 E：转录（独立切片）

- iPhone 的转录 Tab 依赖本地录音/ASR/档案；Android 尚无这些能力。
- 不在 Tab 里放假数据；先隐藏或显示明确的“未接入”，等 sherpa-onnx/录音/同步切片完成后再做。

## 6. 明确不做的

- 不重画一套 Android 专属视觉；不新增 iPhone 没有的主界面按钮。
- 不把 Tailscale/relay/LAN 的配对文案改成另一套。
- 不伪造本地转录、任务状态、记忆或桌面控制。
- 不在本轮提交或推送 Git。
