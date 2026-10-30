# MoMo 桌面常驻入口 · 1.34.0

Hermes 独立分支 `codex/hermes-app-20261021`。本次仅交付 Mac Beta，保持正式版与手机安装独立。

## 两种屏幕，两种入口

- 有真实刘海：MoMo 和任务数位于刘海两侧，内容避开摄像头区域；悬停展开，移开收起，点击可固定，Esc 或点外部收起。
- Mac mini、无刘海外屏：使用原生菜单栏图标与 NSPopover，不生成屏幕顶部的假刘海。显示器变化后重新选择入口，连接变化做短暂防抖。
- 两者复用同一张任务卡：待确认优先、真实任务计数、任务详情回到聊天，次要操作放入“更多”。支持“窗口 → 显示 MoMo”及 ⇧⌘M。
- 菜单栏图标不可见或被排到屏幕外时，快捷键使用可见主窗口作为浮层锚点，避免从屏幕角落出现；展示前先完成内容测量。
- 点击聊天优先激活原窗口；关闭主窗口不会销毁常驻入口。收起时销毁浮层 Avatar/WebView，不持续播放隐藏动画。

状态直接来自现有 `RemoteTaskStore`，不增加网络轮询或另一套 Agent。一个 work 的主运行、进程和委派只计算一次；离线缓存标为待同步；任务结束且汇报完成后移除；汇报失败仍保留提醒。

## 收起跳动修复

旧实现先将 SwiftUI 内容切成 compact 并固定其尺寸，但 AppKit 窗口尚处于 expanded 尺寸，内容被居中放到窗口内部，然后随窗口缩小上移。表现为“先缩成小块，再飞回顶部”。

`DesktopNotchSurface` 始终填满原生窗口、内容顶部对齐。只有 AppKit 驱动窗口尺寸变化，窗口上边缘始终固定；背景随同一个窗口尺寸收缩。减少动态效果时直接切换尺寸。

`NotchSurfaceChecks.swift` 直接实例化产品使用的 SwiftUI 容器与 NSHostingView：先在 400pt 高窗口切换成 compact，再检查 400、320、220、100、38pt 及反向尺寸的中间帧，断言头部始终贴顶、保持 38pt 高且窗口上边缘不动。

## Claude Island 参考

阅读 [Claude Island / Vibe Notch](https://github.com/farouqaldori/vibe-notch/tree/10f1d240e2b4965c2e3c82a3a916458d0541b2be) 的 `NotchWindow`、`NotchWindowController`、`NotchGeometry`、`NotchViewModel`、`ScreenObserver` 与 `Ext+NSScreen`，固定版本为 `10f1d240e2b4965c2e3c82a3a916458d0541b2be`（Apache-2.0）。

参考了非激活面板、空间切换、悬停与点击分开、屏幕变化防抖、独立几何计算这些设计。实现复用 MoMoAgent 的 MoMo 和真实任务状态，没有导入其角色、Claude hooks、声音或代码依赖。该项目的无刘海默认尺寸回退不适用本产品；无物理刘海明确返回 nil，使用菜单栏。面板仅占实际内容区域，也不采用全屏透明窗口和重新注入鼠标事件。

物理刘海的位置使用 Apple 的 [safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets) 和 [auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc) / auxiliaryTopRightArea 的全局坐标计算。

## 本次验证

- Mac Beta 签名构建成功；产物标识 `com.momoagent.mac.beta`，版本 1.34.0，私有数据目录仍为 `MoMoAgent Beta`。
- 状态检查：工作去重、确认优先级、已完成移除、结果汇报失败、取消中、离线、未知状态、本地重放、9+ 计数。
- 几何检查：摄像头避让、顶部锚点、负坐标屏幕、无刘海及辅助区域缺失时返回菜单栏。
- 原生布局检查：收起与展开的中间窗口尺寸均保持 compact 头部贴顶。
- 已安装 Beta 的浮层和在线状态复核通过；菜单栏图标不可见时的窗口锚点回退有真实截图记录。
- 使用独立 QA App/数据目录和 loopback fixture 验证：2 个子进程不会多计任务；7 个任务可滚动到末项；设置入口、Esc 收起、回到原聊天窗口、离线待同步、完成后恢复待机均通过。
- 开发机当前只有 DELL S2722QC 无刘海外屏。真实 MacBook 刘海、实际鼠标悬停及合盖/多屏热切换仍需硬件验收；上述布局回归不冒充硬件验收。此轮没有重新执行手机通信或推送验收。

本地证据：`outputs/hermes-notch-companion-20261025/`（当前 Codex 工作目录）。`menu-expanded.png`、`menu-all-tasks.png` 是本次原生无刘海浮层；早期 `compact.png` / `expanded.png` 为已废弃的外屏假刘海原型，不代表交付设计。

## 重跑检查

先按项目方式构建 `MoMoAgentMacBeta` / `Beta`，设置 `products` 为该构建的 Products/Beta 目录：

```sh
swiftc -parse-as-library -I "$products" "$products/MoMoAgentClient.o" \
  Apps/MacApp/Desktop/DesktopCompanionState.swift \
  Apps/MacApp/Desktop/DesktopNotchLayout.swift \
  Tests/MacDesktop/CompanionStateChecks.swift -o /tmp/momo-companion-state
/tmp/momo-companion-state
swiftc -parse-as-library Apps/MacApp/Desktop/DesktopNotchSurface.swift \
  Tests/MacDesktop/NotchSurfaceChecks.swift -o /tmp/momo-notch-surface
/tmp/momo-notch-surface
```

UI fixture 使用 `Tests/AgentRuntime/serve_companion_fixture.py`，只监听 loopback，不运行模型和电脑任务。必须使用独立 app ID、数据目录与端口，禁止用真实 Beta 数据目录指向 fixture。
