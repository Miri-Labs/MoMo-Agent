# Android 客户端（预览切片）

日期：2026-11-12。状态：首个可运行切片，尚未在真机验收。代码在 `Apps/AndroidApp/`，与 Apple 端共用原有 Mac Access 协议，不新增服务端契约。构建、单测与 lint 结果见[实施记录](../implementation/android-client-20261112.md)。

## 1. 定位

MoMo Agent 的 Personal Agent 入口在 Mac。Android 端作为同一台 Mac 的客户端，复用已有的配对、对话和 SSE 事件通道，让用户在非 Apple 设备上继续同一段对话。Android 不承载 Mac 上的 Agent 运行时，也不复制本地语音转写链路。

这个切片先回答一个问题：**一台没有 Apple 账号体系的 Android 设备，能否安全地配对到已有 Mac，并完成一轮真实的流式对话。** 录音、记忆、资料和主动能力不纳入本切片。

## 2. 当前切片

已实现：

- 扫描 Mac 配对二维码，或粘贴配对 JSON。
- 局域网直连：`network: "lan"` + Mac 自签名 TLS + 二维码证书指纹固定，不依赖 Tailscale。
- 校验配对码版本、应用标识、有效期、HTTPS/回环地址、网络类型、LAN 私有地址与证书指纹，以及身份一致性。
- 在本机用 `SecureRandom` 生成 32 字节 bearer 凭据，通过 `POST /pair/requests` 发起配对，轮询 `GET /pair/requests/{id}`，直到 Mac 本地批准。
- 用 Android Keystore 保护的 `EncryptedSharedPreferences` 保存连接和凭据；解除配对时清除。
- 启动时读取 `GET /momo/v1/conversation/snapshot`，按 `seq` 显示历史消息。
- 通过 `POST /momo/v1/conversation/messages` 发送 `{operation_id, content, intent:"new"}`，从同一响应的 `text/event-stream` 读取 `run.accepted`、`message.delta`、`message.interim` 和终态事件。
- 终态后重新拉取快照，用服务端消息替换本地乐观消息。
- 英文与简体中文界面；浅色主题；CAMERA 权限按需申请。

明确不属于本切片：

- Relay 中继传输（需要 WebSocket 隧道和 relay code 客户端）。
- 录音、蓝牙耳机采集、端上 ASR、声纹和说话人分离。
- 记忆库、转录时间线、生活插画、地图和资料详情。
- 主动提醒、推送、后台任务、跨设备已读和附件。
- Wear OS、平板布局、深色主题、多账号。
- Mac 端设置、模型切换、授权管理和桌面控制。

## 3. 协议边界

只使用 `Apps/MacApp/Access/` 已允许的路由，不代理任意 URL：

| 用途 | 方法与路径 | 认证 |
| --- | --- | --- |
| 发起配对 | `POST /pair/requests` | `Authorization: Bearer <新凭据>` |
| 查询配对 | `GET /pair/requests/{id}` | 同上 |
| 会话快照 | `GET /momo/v1/conversation/snapshot` | Bearer + `X-Hermes-Session-Key: momo:<assistant_id>` |
| 发送消息 | `POST /momo/v1/conversation/messages` | 同上；`Accept: text/event-stream` |
| 能力发现（未接入 UI） | `GET /v1/capabilities` | 同上 |

SSE 帧只包含 `data: <json>`，没有 `event:` 名。首帧是 `run.accepted`，随后是运行事件；事件里的 `message.delta` 是增量，`message.interim` 是整段中间文本。终态为 `run.completed`、`run.failed`、`run.cancelled` 或 `run.interrupted`。未知事件忽略。

局域网模式在同一 public 处理器的 `access port + 2`（默认 8769）上额外提供 TLS 监听；邀请携带 `network: "lan"` 与 `tls_sha256`。客户端固定该证书指纹，连接后仍走同一组 API。详见[局域网直连](lan-access.md)。

连接地址必须是 HTTPS；只允许 `http://127.0.0.1`、`http://localhost` 或 `http://[::1]` 作为本机开发回退。Android 网络安全配置默认关闭明文流量，仅对 `localhost` 与 `127.0.0.1` 放行回环 HTTP。

## 4. 凭据与隐私

- 凭据只在 Android 设备生成，不经过第三方服务；配对响应中的 `connection` 与邀请码的 `instance_id`、`base_url`、`network`、`relay_code`、`tls_sha256` 必须逐项一致。
- LAN 模式用二维码里的证书指纹固定 Mac 的自签名证书，并检查证书有效期；明文 HTTP 局域网地址被拒绝。
- 连接与凭据写入 `EncryptedSharedPreferences`，主密钥由 Android Keystore 保护。解除配对清空该文件。
- 不接入分析、崩溃上报或广告 SDK。对话内容只发往用户自己的 Mac。
- 服务器端 API key 不进入 Android 工程；Android 使用配对换来的设备凭据。
- 源码与同一仓库一致，采用 AGPL-3.0-only。

## 5. 构建与验收

前置：JDK 17+、Android SDK Platform 35、Build Tools 35。Gradle 使用仓库内 wrapper。

```sh
cd Apps/AndroidApp
./gradlew :app:assembleDebug
```

验收本轮切片：

1. `:app:assembleDebug` 成功，产物 `app/build/outputs/apk/debug/app-debug.apk` 存在。
2. `:app:lintDebug` 无新增 error。
3. JVM 单元测试覆盖配对码解析（有效、过期、非 HTTPS、relay）、连接身份校验、消息体序列化和 SSE 帧解析。
4. 真机或模拟器连接已开启入口的 Mac：扫码、Mac 批准、发送一条消息、收到流式回复、重启后仍能读取历史、解除配对后回到扫码页。
5. 同一 Wi-Fi 下使用局域网二维码，确认返回的 `network` 为 `lan`、`tls_sha256` 与邀请一致，并完成一次真实回复。

第 4 项尚未执行；没有真机或模拟器时不得把构建成功记作端到端通过。

## 6. 已知限制

- Mac 未开启任何入口时，`/status` 会返回 503，Android 无法完成配对；局域网模式需要在 Mac 上显式生成局域网二维码。
- Tailscale 场景依赖系统 Tailscale VPN 已连接；客户端不内置隧道。
- Mac 桌面端已在本机构建并启动（本地占位 Sherpa + 真实运行时副本）；“局域网直连”入口可用；正式构建需私有运行库复现。
- LAN 证书在局域网 IP 变化且新地址不在 SAN 中时会重新生成，已配对设备需要重新扫码。
- 会话快照默认一页；更早消息、分页和本地持久化未实现。进程重启后历史从 Mac 重新读取。
- 只显示助手公开正文和工具生命周期，不显示推理内容。
- 未接入 `/momo/v1/conversation/subscribe`，因此其他客户端或 Mac 侧产生的消息不会实时推送到 Android；发送终态后会刷新快照。
- 发送失败时移除该次乐观消息并提示；没有离线发件箱。
- Android 版本号独立为 `0.1.0`，与 Apple 端 `MARKETING_VERSION` 无关。
