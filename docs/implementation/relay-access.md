# 可替换的加密中继连接

2026-11-01。Tailscale 仍是首次连接默认选项；新增主动选择的「加密中继」，不在私网失效时自动切换公网。现有自建 HTTPS 入口继续保留。版本保持 0.0.1。

## 用法

1. 自行部署 [alma-relay](https://github.com/yetone/alma-relay)（Docker / Cloudflare）或 [relay-kit](https://github.com/nanami-0713/relay-kit)（Cloudflare）。使用 HTTPS 根地址；无需转发 Mac 入站端口。
2. Mac 的连接设置选择「加密中继」，填写地址；alma-relay 配置了注册密钥时一起填写。Mac 内置接入层主动建立 WSS 连接，不需要额外安装 Node。
3. 手机连接页的更多菜单选择「加密中继」，扫描 Mac 新二维码并在 Mac 批准。手机不需要登录 Tailscale。
4. 返回 Tailscale 并连接后重新扫码即可切回。切换不删除已授权设备、聊天、资料和任务；客户端继续使用原有工作区/助手/实例身份。

二维码包含独立的随机 256-bit 中继密钥；与现有临时邀请和 Mac 端批准共同使用。密钥不会发送给中继。Mac 在 access 目录以 0600 权限持久保存每个中继的身份，重启和切回同一地址不变更身份。手机随连接配置保存在受 iOS 文件保护的应用目录；现有设备 API 凭据仍放在 Keychain。邀请码过期只阻止新配对，不撤销已授权设备；撤销设备仍通过已有设备管理完成。

## 协议与实现

- `TunnelLifecycle` 管理四种 provider：embedded（默认 Tailscale）、tailscale（外部 Serve）、external（自建 HTTPS）、relay（本次新增）。Relay 自己持有连接任务、心跳与 1–30 秒退避；被另一个 agent 抢占后停止自动重连，需要用户重新连接。
- `RelayTransport` 复用 `AgentTransport`，明确要求独占路由。加密、握手或网络失败绝不回退为明文 HTTPS，也不自动重放写请求；重试继续交给现有任务/同步持久层。`Idempotency-Key`、`Last-Event-ID` 与授权头完整保留。
- 使用 relay-kit 的 `relay-e2e/v1` 协议：临时 P-256 ECDH、带双方公钥和 nonce 的 transcript、HKDF-SHA256、双向独立 AES-256-GCM 密钥、确认值校验及单调计数器防重放。Swift 使用系统 CryptoKit；Python 使用运行环境里已有的 cryptography 50.0.1，并显式列为直接依赖。
- 外层 `/agent?th=…` 与 `/c/<routingToken>/__alma_e2e__` 连接兼容两套中继。alma-relay 只转发内层字节，因此不要求使用其官方客户端协议名。**这是 MoMo 两端之间的连接，不是与 Alma 手机客户端互通。**
- Mac 拒绝来自中继的明文 `hreq` 和非加密 `wopen`。解密后的请求只能访问固定 loopback AccessService 端口及已有路由白名单，不能接触本机管理端口或任意目标。
- 每个 HTTP 交换使用独立加密 WebSocket，取消时关闭该交换并释放服务端任务。响应以 32 KB 分块传输；手机缓冲有界，溢出报错，不丢块。连接/握手/响应都有超时，原有 SSE 消费者继续获得增量数据。

## 当前边界

- 请求体单帧发送，上限 **512 KiB**，为 Workers 的外层 JSON/base64 留出余量。超过限制明确报错，不截断数据或自动改走其他路径。较大附件及大批资料传输继续使用 Tailscale；要解除限制需为两端增加请求体分块协议。
- 聊天、配对、资料 HTTP API 与 SSE 通过此通道；桌面实时视频仍使用现有 Tailscale datagram route，未新增 TURN 或中继视频。APNs 未迁移到中继。
- 公网配置只接受 HTTPS；测试专用内部入口允许 loopback HTTP，配对码和配置 API 不接受该例外。
- 未部署用户的公网中继，也未进行手机真机跨网验收。协议沿用上游方案，未声称经过密码学审计。

## 来源与许可

- relay-kit：`25a142d6527bcab6b98366f3882f11366a3586fb`，重点参考 `PROTOCOL.md`、`packages/core/src/crypto.ts`、`packages/core/src/e2e.ts`；以 CryptoKit / cryptography 原生实现。上游 MIT 许可保留在客户端包的 `Resources/RelayKit-LICENSE` 并随包分发。Copyright (c) 2026 nanami-0713。
- alma-relay：`287107dd2b2a09398d9789c8e6c772a4663e6cd1`，使用公开 wire protocol，与未修改的 Node 服务互通测试；未将服务端代码打进应用。

## 验证与复现

`Tests/AgentRuntime/serve_relay_interop_fixture.py` 启动上游中继及合成 Mac responder，完全隔离用户数据。先在指定的上游 checkout 安装其依赖，再分别运行：

```sh
uv run --with aiohttp --with cryptography==50.0.1 python Tests/AgentRuntime/serve_relay_interop_fixture.py \
  --edition kit --reference /path/to/relay-kit --output /tmp/momo-relay-fixture.json
# 或 --edition alma --reference /path/to/alma-relay
MOMO_RELAY_FIXTURE=/tmp/momo-relay-fixture.json swift test --package-path Packages/MoMoAgentAgentClient
MOMO_RELAY_KIT_REFERENCE=/path/to/relay-kit MOMO_ALMA_RELAY_FIXTURE=/tmp/momo-alma-fixture.json \
  uv run --with aiohttp --with cryptography==50.0.1 python -m unittest discover -s Tests/AgentRuntime -p test_relay_access.py
```

已验证原生 Swift → 两套上游 Node relay → Python responder 的中文 POST、增量 SSE、鉴权拒绝与取消后新请求；Python 加密层与上游 WebCrypto initiator 双向互通、确认值拒绝及重放拒绝；直接向 Alma relay 发送明文 API 请求得到 403。Tailscale 默认值、配置切换/重启的身份保留、配对端点绑定和无明文回退都有自动检查。最终验证：

- Swift 客户端全套 **126 项通过**，包含 relay-kit 本地互通；Alma 本地互通单独通过。
- Python 连接/授权相关 **34 项通过**（relay 5、embedded 4、pairing 11、tunnel 7、tailscale 7）。
- Mac Debug 与 iPhone Simulator Debug（含内嵌 Watch）无签名构建通过；没有安装、启动真实 App 或修改现有配对。
- 一次与双架构编译并行的全套测试遇到原有 `ConversationSubscriptionTests.testMultipleMessagesShareSubscriptionAndLateReceiptCannotRegressPushedCompletion` 时序断言失败；单独复查及停止编译后的整套 126 项均通过，未改动该业务测试。
- 构建最初因临时目录别名导致上游二进制包解压失败，改用普通工作目录完成构建；模型/框架仅临时链接现有本地产物，验证后移除链接与构建缓存。
- 代码留在 `codex/alma-relay-20261101` 独立分支；未合并 main、未推送。公网 TLS、Cloudflare Worker 部署、移动网络和真机验收仍待实际中继配置后验证。

清理完成：已停止本轮两个合成中继，删除本轮 Xcode/SPM 构建目录、上游参考临时副本与框架/模型链接。未改动已安装 App、用户数据、主工作目录及主线程的构建。收尾读取磁盘可用空间约 13.5 GiB；此值不是本轮释放量。
