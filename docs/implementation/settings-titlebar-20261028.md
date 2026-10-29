# MoMo Agent 设置窗口顶部连续背景 · 2026-10-28

交付版本：1.38.2。基线：`5d9b7cf1`，保留 main 已合入的记忆阅读器与 Dream 状态。

## 修复

`Settings` 场景会应用自己的 `windowToolbar` 背景。即使 `DesktopWindowChrome` 已设置 `fullSizeContentView`、透明标题栏与隐藏标题，该背景仍覆盖窗口顶部 32pt，使两栏背景出现横向白条。

- 在 SwiftUI 设置根视图明确隐藏 `windowToolbar` 背景。macOS 15 及以上同时移除默认 toolbar title，避免切换 tab 后再次显示系统窗口标题；macOS 14 保留原 AppKit 隐藏标题行为。
- 两栏背景各自延伸至 container safe area；先让两栏忽略安全区，再应用窗口尺寸约束。侧栏标题顶部间距由 52pt 调为 48pt，与右侧标题对齐。
- 保留原 Settings scene、原生红绿灯、窗口尺寸、滚动、可访问性标识和配对/权限状态。没有修改宿主的 `safeAreaRegions` 或 `sizingOptions`，没有添加标题栏遮盖层。
- Pen 中六个设置画板保持侧栏从 y=0 开始，顶部原生控件标为浮层，侧栏标题同步到 48pt。视觉规范继续引用 [Typeless bundle 复核](../design/settings-hierarchy-20261027.md)。

## 验证与安装

本地证据目录：`/Users/syh/Workspace/MoMo-Agent-deliveries/main-1.38.2/validation/`。

- Mac Release 编译成功（`mac-build-final.log`），Apple 签名校验通过，已覆盖安装 `/Applications/MoMo Agent.app`。安装包版本为 1.38.2，内部安装序号 161；designated requirement 与更新前一致。
- 实际打开模型、设备、记忆、通用、连接方式与权限窗口，检查标题、行布局及返回；关闭并重开设置后再次核验。主窗口背景与导航保持正常。
- 六张最终设置截图通过像素连续性检查（`titlebar-pixels-final.log`）：顶部与下方侧栏均为截图色值 244，画布均为 250；侧栏源色仍为 sRGB #F3F3F3，截图存在显示色彩转换。实际窗口截图为 1360×944，未出现异常高度增长。最终代码不含临时窗口诊断。
- iPhone Release build-for-testing 成功；使用 `MoMoAgentLocal.entitlements` 个人团队签名，DerivedData 位于 `~/Library/Caches`。发布包 29 项静态检查通过，手机、内嵌手表及 widget 版本一致。
- 真机 `00008150-000A31AA1447801C` 安装与启动成功，设备读回 MoMo Agent 1.38.2 / 161。通过设备窗口实际检查设置首页、版本、Mac 连接、记忆、健康、到访地点与语音检测；保留原配对和开关，连接页显示已连接。截图为 `phone-*-live.png`。
- 真机 XCTest runner 在建立 IDE DTX 通道前以 code 74 退出，没有执行测试，不能记为通过；上述真机验收来自手动导航。储存空间页在本轮观察期间仍显示统计中，不据此宣称储存统计功能已验证。未修改手机设置业务代码。
- 安装和手动检查完成后，收尾时 Device Hub 与 `devicectl` 将 iPhone 报为 unavailable（`phone-devices-at-close.json`）；此前安装、版本读回和页面检查已完成，不将先前连接成功表述为设备此刻持续在线。

本轮仅在默认字号验证。验收后移除本轮 DerivedData、像素分析模块缓存、临时诊断及中间安装备份；保留交付包、运行源码和验证证据。
