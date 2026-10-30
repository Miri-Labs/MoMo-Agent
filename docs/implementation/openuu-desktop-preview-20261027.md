# 控制电脑：连续画面与接管修复（2026-10-27）

本轮代码已按用户追加要求整合到 `codex/hermes-app-20261021` 的未提交工作区，独立工作树保留供复查。未安装应用、未重启用户服务、未改变系统授权或推送。用户明确不要的“画面停滞”标记没有加入。合并后验证见 [整合记录](hermes-integration-20261027.md)。

- 分支：`codex/desktop-preview-fix-20261027`
- 工作树：`/Users/syh/Workspace/MoMoAgent-worktrees/desktop-preview-fix-20261027`
- 基线：`eab661fa007406e5d38b33d6d4308a1542232e5a`
- 原 Hermes 工作树的未提交内容已保留；`PhoneDesktopView.swift` 的原有重连交互通过手工合并保留。

## 实际证据与根因边界

任务开始时实际运行的 Mac 是 Beta **1.34.17**，来源 `MoMoAgent-deliveries/hermes-1.34.17`；手机是 Beta **1.34.16**。不是转交说明中旧的 Mac 1.34.16。手机正式版 1.19.8 未改动。

1. 从运行中的 Mac 原生 Unix IPC 只读检查：屏幕录制、辅助功能、配对均为可用。一次真实截图约 **353 ms**，有效 JPEG **394,166 字节**、1080×1920。没有保存或展示用户屏幕内容。这只能证明该次原生采集正常，不能证明手机已经解码呈现。
2. 当前唯一显示器为 DELL S2722QC，主屏 ID 2、1080×1920；采集尺寸与真实竖屏一致，没有“选错虚拟屏幕”的证据。
3. 手机 12:46–12:49 的真实网络日志：多次 desktop GET 响应头约 1.4–2.6 秒到达，但整个请求耗时 **14.9、20.6、21.5、23.0、41.9 秒**。旧日志仅标记 desktop，未记录 frame/status 子路由，不能把每一条 GET 都直接当成已精确关联的截图请求；长响应体等待与旧截图路径的问题一致。
4. 接管操作确实生效：租约变为 human、epoch 8；随后 POST 有 20.3/26.8 秒等待和 409。旧租约有效期仅 20 秒，因此“点了接管后失效”不能归因为按钮没发出请求。控制请求延迟超过租约时限是实测问题。
5. 代码链路：旧手机每轮 **取状态 → 完整 base64 JPEG → 解码 → 等 500 ms**；大图未完成时不会开始下一帧。桌面控制、心跳、截图和背景同步共用普通 Tailscale URLSession 池。最后一张图一直保留，因此长等待看起来就是静止图片。HTTP 200 与首帧成功也没有分开；`byPreparingForDisplay()` 返回 nil 时可清空画面却仍标记 connected（潜在缺陷，本机未复现 nil）。

结论：已确认串行整图请求、共享池和缺少端到端画面背压；实测存在长传输等待与接管租约过期。尚未证明这 15–42 秒全部来自 Tailscale、特定代理或某一个解码 API，不能拿当前修复后的模拟结果冒充实机根因闭环。

证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/desktop-preview-20261027/`。`live-native.json` 为原生检查元数据，`phone-before-timings.json` 为只含计时的手机记录，无凭据或消息正文。

## OpenUU 参考与许可证

核对了用户指定的 [v0.7.0](https://github.com/djkcyl/openuuyc/tree/c40072e24a9191885343bfe979242cc201073afc)，并阅读本地已缓存的新版本 `a87b8e772c238e542215ab039f1b1d2ca4a9ef46` 的对应实现：

- [capture_worker.rs](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/src/features/host/peer/capture_worker.rs)：持续采集、来源变化重建、背压与自适应。
- [decode_pipeline.rs](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/src/application/viewer/decode_pipeline.rs)：解码代次、丢弃旧回调、只保留最新可呈现图像。
- [connection_progress.rs](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/src/application/viewer/connection_progress.rs)：连接与首帧就绪分别判定。
- [shared.rs](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/src/session/controller/shared.rs)、[takeover.rs](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/src/session/controller/takeover.rs)：设备连接的所有者、观看生命周期与控制权独立管理。

两次核对的 [LICENSE](https://github.com/djkcyl/openuuyc/blob/a87b8e772c238e542215ab039f1b1d2ca4a9ef46/LICENSE) 都不是整项目开源授权；源码公开不授权整体复制。这里独立实现机制，没有复制或翻译其保留权利的 Rust 源码，没有引入 Ponytail。

## 已实现链路

| 环节 | 本轮实现 |
|---|---|
| 采集 | 一个持续的 ScreenCaptureKit SCStream，10 fps 上限；只保存最新完整图像；8 秒无人读取后释放；主屏或物理分辨率变化后重建；旧 stream 回调不覆盖新来源。 |
| 编码 | 后台 JPEG 编码；最长边有界，竖屏也不会超过解码上限；首帧 640，依据手机确认时延在 320–1280 间调整；返回编码后的真实尺寸。 |
| 连续传输 | 新增 `/desktop/v1/frames` 二进制 multipart JPEG 流，消除逐帧 HTTP 请求及公网传输的 base64 膨胀；继续走内嵌 Tailscale 私网或已配置的 HTTPS relay。 |
| 端到端背压 | 每帧带 stream UUID 和 sequence。手机解码并交给图像视图状态后发 `/frame-ack`；最多两帧未确认，之后停止编码新帧，确认后直接取最新采集。ACK 属于本配对、本流，不能确认未来序号；5 秒无确认关闭并允许恢复。系统显示刷新时刻未做 CADisplayLink 实测，ACK 不等同于测得屏幕扫描完成。 |
| 接收与解码 | URLSessionDataDelegate 按块接收；有界 multipart 解析后仅保留最新完整 JPEG，绝不丢半个 JPEG；ImageIO 后台解码并检查像素尺寸，成功首帧才就绪。 |
| 接管 | 桌面控制、画面和聊天/同步分开 URLSession 池；接管/输入/心跳不等待画面编码或媒体发送。保留服务端配对验证、独占租约、序号和输入去重，不重放结果未知的点击。 |
| 恢复 | 流中断后重新建立；同设备新观看连接替换旧连接；手机 scene 代次阻止旧回调回写，退出停止输入和接收；保留重连期间最后一张图，没有添加停滞标记。没有新鲜图像时不接受输入。 |
| 兼容 | 未声明 `preview_stream` 的旧服务器仍走原 frame API；新版配对默认使用新流。普通 HTTPS relay 的视频不挤占 RTC 有序控制 DataChannel；私网不可回退普通网络。 |
| 诊断 | 细分 desktop-frames / frame / status / control，记录响应体字节数与耗时；不记录凭据、输入文字或图片内容。 |

**协议边界：这版是连续 JPEG + 接收确认，不是 OpenUU 的 H.264/H.265、硬件视频编码或 RTP 视频轨移植。** 因而没有声称全面复制 OpenUU、达到其帧率/码率或跨网延迟。Tailscale、现有配对和 Hermes 控制权保留为 MoMoAgent 自己的网络与授权体系。

## 改动位置

- `Apps/MacApp/Desktop/DesktopScreenStream.swift`、`DesktopControlHost.swift`：持续采集和有界编码。
- `Apps/MacApp/Access/desktop_control.py`、`access_server.py`、`rtc_transport.py`：媒体流、配对验证、窗口确认和路由。
- `Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/DesktopJPEGStream.swift`、`DesktopClient.swift`、`AgentClient.swift`、`AgentTransport.swift`：分帧、按块接收、确认、取消和首帧 API。
- `Packages/MoMoAgentAgentClient/Sources/MoMoAgentRTC/AgentRTCTransport.swift`：媒体不进入有序控制通道。
- `Apps/ClientUI/Network/EmbeddedTailnet.swift`、`EmbeddedTailnetTransport.swift`、`TailnetDiagnostics.swift`：独立池与诊断。
- `Apps/iPhoneApp/Features/RemoteAgent/PhoneDesktopSession.swift`、`PhoneDesktopView.swift`：生命周期、解码和就绪交互；从 View 提取模型便于直接测试。
- `MoMoAgent.xcodeproj/project.pbxproj`：XcodeGen 2.46.0 注册新 Swift 文件。
- 新增/更新测试：`DesktopStreamTests.swift`、`PhoneDesktopSessionProbe.swift`、`test_desktop_control.py`、`DesktopControlProbe.swift`、`test-tailnet-recovery.py`。

## 真实验证

全部命令在上述独立工作树执行。Python 使用已经存在的 Beta 私有运行时，经 uv 调用；没有安装应用或系统依赖。测试服务器仅使用临时数据与本机临时端口；native probe 仅验证拒绝路径，不发送真实键鼠事件。

```sh
swift test --package-path Packages/MoMoAgentAgentClient --scratch-path tmp_agent_output/client-tests
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' -m unittest discover -s Tests/AgentRuntime -p test_desktop_control.py -v
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' Tests/Support/test-tailnet-recovery.py
```

- Swift 包：**101 tests / 0 failures**。覆盖任意分块边界、多个合并帧、损坏/超长帧、旧服务端兼容、按块接收与取消、私网不得回退普通网络，以及现有聊天回归。
- Python：**15 tests / OK**。覆盖慢采集不阻塞接管/心跳、连续不同帧、撤权终止、两帧确认窗口、非法 ACK、租约/输入去重边界。
- Tailnet lifecycle probe：**PASS**。控制/媒体/聊天/同步池分离；仅修复出错的池，节点与其他请求不被重启。
- 原生 Swift probe：编译通过，**6 条 IPC/权限拒绝/控制权测试 PASS**；另验证极端横竖尺寸的最长边限制。
- iOS Simulator 独立可执行 probe：**PASS**。使用真正的 `PhoneDesktopSession`、AgentClient、ImageIO 和合成红蓝帧，验证首帧就绪、像素变化、接管、输入、重连、交还及取消后的旧帧不会回写。直接 `simctl spawn`，没有安装测试 App；这不是实际手机的端到端画面验收。

原生 probe 的真实编译命令：

```sh
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 Tests/AgentRuntime/DesktopControlProbe.swift Apps/MacApp/Desktop/DesktopControlHost.swift Apps/MacApp/Desktop/DesktopInputDriver.swift Apps/MacApp/Desktop/DesktopScreenStream.swift -o tmp_agent_output/desktop-control-probe
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent Beta/Agent/runtime/venv/bin/python' Tests/AgentRuntime/run_desktop_control_probe.py
```

两端完整 Beta 构建均用 `CODE_SIGNING_ALLOWED=NO`，只用于编译验证：

```sh
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgentMac -configuration Beta -destination 'generic/platform=macOS' -derivedDataPath tmp_agent_output/build -clonedSourcePackagesDirPath /Users/syh/Library/Developer/Xcode/DerivedData/MoMoAgent-hjpgcgoaxtzeszdeeexelycflvge/SourcePackages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgentBeta -configuration Beta -destination 'generic/platform=iOS' -derivedDataPath tmp_agent_output/build -clonedSourcePackagesDirPath /Users/syh/Library/Developer/Xcode/DerivedData/MoMoAgent-hjpgcgoaxtzeszdeeexelycflvge/SourcePackages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

`mac-build.log` / `phone-build.log` 中记录最终构建结果。构建临时引用现有 Models、TailscaleKit Build 和 SherpaOnnx Binaries，没有复制模型或更改原目录。交付清理本轮约 2 GB 的 DerivedData/SPM 产物与临时链接，保留源码和上述日志。

## 尚未验收与集成方式

由于本任务明确禁止安装和重启，运行中的 Mac/iPhone 仍是旧版；新 SCStream 在真实 Beta 授权进程内的持续采集、真机触控、蜂窝/异地 Wi-Fi、慢网分辨率变化、长时间运行、锁屏/显示器休眠与恢复，都没有宣称通过。原生读取权限成功不替代这些验收。

补丁相对 eab661fa 生成在证据目录 `desktop-preview-fix.patch`。原 Hermes 工作树有并行未提交修改，不能直接覆盖或 reset。应先合并 `PhoneDesktopView.swift` 的网络重连接口到新 `PhoneDesktopSession.swift`，其余文件按补丁逐项复核；完成之后再单独构建、签名并安排获准的安装验收。本轮不提交、不集成到原工作树。
