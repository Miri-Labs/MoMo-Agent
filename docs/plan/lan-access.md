# 局域网直连（安全 LAN 模式）

日期：2026-11-12。状态：Mac 协议层与 Android 端已实现并通过本轮验证；Mac App 的可视入口已写入源码，但本机无法重新编译，iOS 端尚未接入。相关待办见 [局域网直连待办](../todos/lan-access.md)。

## 1. 问题

现有连接方式只有 Tailscale 私网、加密中继和自建 HTTPS 服务器。手机与 Mac 已经在同一个 Wi-Fi 时，仍需登录 Tailscale 或搭反向代理，这是产品缺口，不是配置错误：

- `Apps/MacApp/Access/access_server.py` 的 public 应用只监听 `127.0.0.1`。
- `pairing_store.endpoint()` 只接受 HTTPS 或回环 HTTP。
- iPhone/Android 客户端同样只接受 HTTPS 或回环 HTTP。

## 2. 设计

新增 `network: "lan"` 的配对邀请：

1. Mac 在 `access/lan/` 生成并持久化一张自签名证书，证书 SAN 包含当前所有 RFC1918 IPv4 地址。
2. 用户选择“局域网直连”时，Mac 在 `0.0.0.0:<access port + 2>` 启动一个仅服务该证书的 TLS 监听（默认 8769）。
3. 二维码载荷包含：
   - `endpoint`: `https://<primary-lan-ip>:<port>`
   - `network`: `"lan"`
   - `tls_sha256`: 证书 DER 的 SHA-256 十六进制指纹
4. 客户端用二维码里的指纹固定服务端证书，不依赖系统 CA、Tailscale 或中继。
5. Mac 本地仍需批准数字代码；配对后使用同一个 bearer 凭据和 `X-Hermes-Session-Key` 访问原有 API。

这样局域网内没有明文传输，也不把 Mac 暴露给没有二维码指纹的客户端。Mac 的 public 处理逻辑、允许路由表和上游认证保持不变。

## 3. 当前实现

Mac：

- `Apps/MacApp/Access/pairing_store.py`：`is_lan_address`、`is_lan_endpoint`，`network == "lan"` 只接受私有 IPv4 + HTTPS + 根路径。
- `Apps/MacApp/Access/lan_access.py`：证书生成/复用、指纹、`0.0.0.0` TLS 监听、停止。
- `Apps/MacApp/Access/access_server.py`：`/pair/invite` 支持 `{"lan": true}`；`status` 返回 `lan` 状态；LAN 端点识别后注入 `network` 与 `tls_sha256`；public 与 SSE 鉴权同时接受活跃的 LAN 监听。
- Mac 桌面端：`DesktopModel` 解码 `lan`；连接方式增加“局域网直连”；配对页在 LAN 邀请存在时显示二维码。

Android：

- `PairingInvitation` / `AgentConnection` 支持 `tls_sha256`。
- `PairingCode` 接受 `network == "lan"`，要求 HTTPS、私有 IPv4、64 位小写十六进制指纹，并校验配对返回的连接与邀请一致。
- `PinnedTls.kt` 只信任指纹匹配的叶证书，并检查证书有效期。
- `AgentApi` 对 LAN 连接使用固定证书的 OkHttp 客户端（含 SSE）。

## 4. 安全边界

- 局域网模式不是明文模式。证书是自签名的，但客户端只接受二维码给出的指纹，避免同网段中间人替换证书。
- 二维码本身是配对凭据：不应转发给不受信任的人；邀请 5 分钟过期，且仍需 Mac 本地批准。
- 证书私钥保存在 `~/Library/Application Support/MoMoAgent/Agent/access/lan/`，文件权限 0600。
- Mac 防火墙可能提示允许 Python/MoMo 接收局域网连接；拒绝时监听无法从其他设备访问。
- 证书默认有效期 365 天。局域网 IP 变化且新地址不在证书 SAN 中时会重新生成证书，指纹随之变化，已配对的 Android 设备需要重新扫码配对。
- 中继模式仍不支持 Android 预览；LAN 与 Tailscale 是两条独立路径。

## 5. 验证

- Python 单元测试：`Tests/AgentRuntime/test_lan_access.py`、`test_pairing.py`，15/15 通过。
- Mac 端独立端到端：临时数据目录、备用端口、真实运行中的 Mac Agent。生成 `https://10.1.20.155:8869`、证书指纹、配对请求、Mac 批准、连接返回 `network=lan`/`tls_sha256` 匹配、快照 200（cursor 172，8 条消息，2 个 run）。
- Android：`:app:assembleDebug` 通过；21/21 JVM 测试通过（含自签名证书固定成功与错误指纹拒绝）；`:app:lintDebug` 0 error。
- **未完成**：Mac App 重新编译与可视化流程验证（本机私有 Sherpa 运行库不可用）；Android 真机配对；iOS 客户端。

## 6. 验收

1. Mac 与手机在同一 Wi-Fi，Mac 连接方式选择“局域网直连”，显示二维码。
2. Android 扫码后显示 6 位数字，Mac 显示相同数字并批准。
3. Android 能读取同一段会话历史并发送一条流式回复。
4. 明文 HTTP 局域网地址、公网 IP、缺失/错误指纹均被拒绝。
5. Mac 关闭远程访问后，LAN 监听停止，手机无法继续访问。

第 4、5 项已由单测和独立服务验证；第 1–3 项的 Mac UI 与真机部分待补。
