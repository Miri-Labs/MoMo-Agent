# Mac 权限拖放引导

用户要求移除“已开启，仍然不可用？”说明与 Finder 链接，并参考 Codex 的拖放授权交互。当前实现依据本机 bundle 的静态分析，未访问或改写 Codex 的权限配置、签名和运行进程。

## 来源与纠正

本机 `Codex Computer Use.app/Contents/MacOS/SkyComputerUseService` 的符号、Objective-C 方法及相邻汇编确认：

- `PermissionWindowController` / `PermissionRowRegistry` 管理总览、当前权限和来源行。
- `SystemSettingsAccessCoordinator` 单独负责开启设置、呈现 accessory 和等待用户拖入；存在正向/反向 transition 回调。
- `SystemSettingsAccessoryWindow` 带 `ArrowWindow`，`canBecomeKeyWindow` 与 `canBecomeMainWindow` 均返回 false。
- `DraggableApplicationView` 拖的是 `appRowView` 的快照，提供 `NSPasteboardTypeFileURL`。`acceptsFirstMouse` 返回 true，开始拖动隐藏原条目，结束后恢复；只有 copy 结果通知协调器。取消/失败允许回弹。
- `SystemSettingsApp` 观察设置窗口、滚动及 audio-only 标题边界，说明引导依附具体设置内容，而非固定在桌面左边的第二个权限总览。

关键静态地址：`mouseDown:` 0x100fbf664；原生拖放构建 0x100fbf408；开始隐藏 0x100fbf6c0；结果处理 0x100fc1414；首次鼠标 0x100fbf834；非激活窗口 0x100fba3f8。

这纠正了最初“普通浮窗 + 大图标 + 两行按钮”的错误理解。未将 Codex 的二进制、图片、专有代码拷入仓库。官方 [Computer Use 文档](https://learn.chatgpt.com/docs/computer-use) 只用于确认权限类型，不作为拖放动画证据；工具禁止控制 Codex 自身窗口，因此没有声称看过其运行时动画或做到像素级复刻。

## 实现

- `DesktopPermissions.swift`：总览只列两项权限；选择后显示小型拖放引导，可拖完整 App 条目。AppKit 原生 file URL、首次点击可拖、失败回弹、拖动时隐藏原条目。移除旧故障说明和 Finder 链接。
- `DesktopPermissionState.swift`：以实际 `AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess` 为准。打开设置、copy drop 都不等于已授权；允许取消、重试和撤销状态更新。
- `DesktopPermissionsController.swift`：总览与非激活引导窗分开，跟随系统设置；有辅助功能权限时定位第一张权限列表，避免把屏幕录制拖入第二张“仅系统录音”列表；尚无权限时使用上半部内容区域作为保守位置。界面关闭停止轮询，设置关闭返回总览，权限生效返回总览并勾选。AX 读取有时间预算、深度和节点上限。
- `DesktopViews.swift`：显式“管理权限”打开该流程，不依赖 Agent 运行时是否就绪。

没有添加自动 TCC 重置、后台弹窗、远程请求触发设置、自动授权或 App 重启。macOS 自己若要求重新打开 App，仍由系统处理。本轮借鉴分步引导和拖动行为；未实现 Codex 专有的快照形变动画。

## 验证

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Apps/MacApp/Desktop/DesktopPermissionState.swift \
  Tests/AgentRuntime/DesktopPermissionProbe.swift -o /tmp/momo-permission-probe
/tmp/momo-permission-probe
PYTHONDONTWRITEBYTECODE=1 uv run --no-project \
  --python '/Users/syh/Library/Application Support/MoMoAgent/Agent/runtime/venv/bin/python' \
  -m unittest discover -s Tests/AgentRuntime -p test_desktop_control.py -q
```

- Swift 探针通过：显式操作、真实状态/撤销、打开失败/重试、含空格和中文的 App 文件 URL、拖放成功/取消与返回。
- 原有控制权限回归：15 项通过。
- 使用真实生产视图/控制器的隔离 QA App：总览 → 辅助功能引导 → 返回 → 屏幕录制引导可操作；Escape 关闭和重复打开已测。原生接收区实际收到 `MoMo Agent.app`，并触发成功反馈。测试接收区不更改 TCC。
- Mac Release：Apple Development 签名构建通过。最终构建使用 main 新增系统代理支持的 TailscaleKit XCFramework，不能回用旧缓存。
- SwiftUI 静态扫描：0 high；固定桌面窗宽、拖动行高度及图标尺寸已在默认字号检查。原生语义可由 AX 读到；未运行 VoiceOver 朗读/高对比矩阵，视觉验收暂定 84/100，不宣称完整无障碍验收。

未验收：在一个真正未授权的用户账户中，把 App 拖入系统设置、通过 macOS 身份验证、两项权限实际生效的全流程。现有 MoMo 权限开关已开启，本轮没有撤销它们来伪造首次授权，也没有把 QA 接收区成功当作系统授权成功。

## 本机交付

Mac 正式版已覆盖更新到 **1.36.2**。安装前确认 Hermes admission 全部为 terminal；保留数据、配对和系统授权，使用旧 App 相同的叶证书重新签名，designated requirement 完全一致，`codesign --verify --deep --strict` 通过。实际启动 `/Applications/MoMo Agent.app` 后，在“设置 → 高级 → 管理权限”核对两项均显示“已开启”，旧故障说明与 Finder 链接已消失。

产物及冻结运行源码位于 `/Users/syh/Workspace/MoMo-Agent-deliveries/main-1.36.2/`。此次只更新 Mac，未重新安装手机或手表。隔离 QA App 和本轮构建缓存完成验证后清理；保留共享模型、SDK、工具及实际用户运行目录。
