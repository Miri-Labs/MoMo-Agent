# MoMo Agent 远程桌面视频（1.37.0）

## 取舍与来源

用户要求编码视频 + WebRTC，并参考 Dots / OpenUU 的视频、控制和接管分层。此次独立实现，没有复制 Dots 私有 bundle 或 OpenUU 非通用开放许可的源码。保留 WebRTC 与 TailscaleKit 的上游许可证。

- Dots：本机 ChatGPT 26.1021.31345 bundle 的云桌面使用 RTCPeerConnection、视频 track、DataChannel 控制和 SDP HTTP 信令。其本机 PIP 另有 VideoDecoder/VideoToolbox 路径；不能将两者说成同一实现。
- OpenUUYC：本地研究副本 a87b8e772c238e542215ab039f1b1d2ca4a9ef46，参考 capture_worker / decode_pipeline / transport/rtc 和 controller 的职责与生命周期。
- 之前的 `/desktop/v1/frames` 是 JPEG multipart。真实 CFNetwork 会解析 multipart、将裸 JPEG 分段交给 delegate，旧解析器却再次期待边界，因此 mocked URLProtocol 测试通过不能证明 iPhone 可播放。

## 新数据路径

Mac ScreenCaptureKit → CVPixelBuffer → WebRTC H.264 / VideoToolbox → RTP/DTLS/SRTP → 内嵌 Tailscale UDP → iPhone WebRTC 解码 → RTCMTLVideoView。

同一个 PeerConnection 的有序 DataChannel 传递 status / claim / release / heartbeat / input。手机的有界输入队列、移动合并、event UUID、sequence 和 Mac 独占租约继续有效。Python 只负责可信设备、信令、控制授权；不转码、不承载视频。

`POST /desktop/v2/offer` 仍使用配对 token。SDP 上限 128 KiB、nonce 校验，只允许视频与数据通道；不传音频。对外仅交换 tailnet 地址，不暴露 LAN 候选。内嵌 Tailscale 无系统 VPN，因此 SDK 增加每个会话的回环 UDP bridge：native libwebrtc 连接回环，bridge 固定 native ICE 源端点与远端 tailnet 端点，丢弃其他来源。每节点最多 4 个 bridge；节点关闭统一释放；不存在普通网络回退。

当前实现使用 IPv4 native ICE 源候选和 tailnet IPv4。IPv6-only 蜂窝网络尚未验收；这不影响 Tailscale 底层通过 IPv6 联网，但纯 IPv6 native ICE 源仍需单独支持。自建公网 relay 的媒体 ICE/TURN 不在本次默认链路内，不能把 HTTPS relay 等同于此媒体桥。

## 生命周期与安全

- 真实首帧解码之后才可接管；HTTP 200、DataChannel open 都不表示画面已经显示。
- 桌面静止时复用最近的有效 CVPixelBuffer 维持低频 RTP；屏幕不可用时清空缓存，不重播无效画面。
- 关闭、退后台、断线或新连接替换时关闭 peer、屏幕采集与 UDP bridge。视频故障不重启聊天的 Tailscale 节点。
- 已有配对审批保持不变。每条控制命令及周期检查重新验证设备授权、远程开关、屏幕权限和接管所有者。
- 数据通道控制仅转交 API-key 保护的本机 `/desktop/rtc`，公网不暴露该路由；收到的 viewer 字段不能覆盖配对身份。
- 不添加停滞画面标签。真实失败保留重连动作；不使用静态图片伪装连续视频。
- 诊断只保留有界帧计数、codec、时间、操作类别和响应码；不记录画面、SDP、凭据、键入内容或坐标。
- Agent 的单次截图工具仍可使用 JPEG；旧客户端 v1 接口保留兼容，新手机“控制电脑”不再使用图片轮询/multipart。

## 已执行验证

- Mac 与 iPhone Release 构建通过；本机个人签名继续使用原有 Local entitlement，不声称 APNs 已开通。
- `uv run --with aiohttp --with 'mcp>=1.26' python -m unittest discover -s Tests/AgentRuntime -p test_desktop_control.py`：18 项通过。
- `uv run --with aiohttp --with aiortc python -m unittest discover -s Tests/AgentRuntime -p test_webrtc.py`：12 项通过、4 项既有 native chat/TURN 集成因未设置独立环境变量跳过。新桌面 HTTP 授权边界测试通过。
- `cd Vendor/TailscaleKit && go test -run TestMedia -count=1 .`：路由固定、拒绝外部端点、双向来源过滤、关闭释放通过。
- `uv run python Tests/Support/run-desktop-rtc-smoke.py --webrtc <cached WebRTC macOS framework directory>`：真正两个原生 WebRTC peer、两个隔离 tsnet 节点和本地控制/DERP；5 秒收到 127 帧、105 种解码后亮度，H.264 27 fps，DataChannel 往返及关闭时 pending request 结束通过。测试是动态图形，不是用户屏幕，也不是实机跨网验收。
- `swift test --package-path Packages/MoMoAgentAgentClient --scratch-path tmp_agent_output/agent-tests --filter DesktopStreamTests -j 2`：6 项通过，含视频 answer nonce/version/大小校验与私网不回退。
- `run-desktop-rtc-smoke.py --capture` 使用真实 ScreenCaptureKit 桌面，未存储任何画面：5 秒 144 帧，720×1280，29 fps；Mac encoderImplementation=VideoToolbox、powerEfficientEncoder=1。接收端是同机原生测试 peer，不能当作 iPhone 实机验收。该测试发现 SDK 默认协商的 H.264 level 3.1 在 810×1440 输入下没有编码输出，因此产品把单帧 macroblock 数限制为 3600、最长边 1280，且覆盖正方形和超宽屏尺寸。
- 已安装 Mac 1.37.0，严格签名检查通过，保留原证书与 designated requirement。UI 核对两项系统权限仍为“已开启”；真实 `/desktop/rtc` 管理路由→Python 授权→native IPC 返回 approved/screen/input=true。验证时补齐了原生数据通道入口在本机路由表中的注册，并为真正的 router 增加回归。
- Hermes gateway PID 56244 保持不变，只更换连接服务；升级前 248 条 admission 全为 terminal。配对、录音、记忆和会话数据不改写。
- 交付保留本机 1.36.4 的设置改动（settings-hierarchy 的三个已提交变更），没有改动其工作树中的未提交文件。
- 旧 PhoneDesktopSessionProbe 的 multipart 假传输已移除，不能继续用它声称真实视频/手机生命周期通过。

iPhone 1.37.0 安装包已构建并通过静态 bundle 验证。开发连接仍为 unavailable，尚未安装；手机视频显示与手势接管、退后台恢复、异地/蜂窝网络仍未验收。未通过的实机项不能由上述原生测试代替。

交付与验证记录：`/Users/syh/Workspace/MoMo-Agent-deliveries/main-1.37.0/validation/`。只将 Mac 安装标为完成，手机安装与实机验收分别跟踪。
