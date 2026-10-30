# 双端内嵌 TailscaleKit

当前版本 **1.29.4**，只在 `codex/hermes-app-20261021` 开发。用户确认改用 Tailscale 加密网络内的 HTTP / SSE；1.29.1 的 HTTPS 引导、证书检查和教程图片已移除。

## 产品路径

Mac：准备运行组件 → 连接模型 → 登录 Tailscale → 显示二维码 → 允许手机。

iPhone：登录同一 Tailscale 网络 → 扫码 → 核对数字 → 等待 Mac 允许 → 聊天。

不要求安装独立 Tailscale App、配置系统 VPN、MagicDNS、证书或执行 Serve 命令。登录通过 ASWebAuthenticationSession 打开官方网页；节点实际 Running 后才推进。Tailscale 账号若启用设备审批或 ACL，仍需满足账号自身的规则。

Mac 使用官方 Tailscale 图标与字标，一个主动作；失败时原位重试。自建服务器与退出账号收入更多菜单。配对弹窗随内容高度调整，最多 640pt，可滚动；保持现有录音、记忆、聊天与运行组件下载进度设计。

## 网络边界

```
iPhone AgentClient / PairingClient / ContextSync
  → EmbeddedTailnetTransport → URLSession + Kit SOCKS5
  → Tailscale 加密私网（直连或 Tailscale 中继）
  → Mac tsnet.Listen("tcp", ":8767")
  → 127.0.0.1:AccessService → Hermes / Context / device grants
```

SDK 源码与上游记录在 `Vendor/TailscaleKit`。`Listen` 只监听内嵌节点，未在系统网卡开放 HTTP 端口。转发目的地固定为本机 AccessService；SSE 即时 flush，Authorization、Idempotency-Key、Last-Event-ID 保持原协议。

- 配对地址使用节点 IPv4 `http://100.x.x.x:8767`，地址必须属于 `100.64.0.0/10`。不依赖 DNS 名称或 HTTPS Certificates。
- QR 明确标记 `network: tailscale`；Mac、手机与持久配对恢复都校验网络类型和地址。普通公网 HTTP、LAN 地址、任意端口、带用户信息的 URL 均不能作为私网入口。
- 手机要求独占的 EmbeddedTailnetTransport；节点离线、代理失效或 transport 返回 nil 时直接失败。HTTP、SSE、配对均不得回退系统 URLSession；禁止重定向和 SOCKS failover。
- 两端 ATS 只为 `100.64.0.0/10` 放开应用内 HTTP，不启用 NSAllowsArbitraryLoads。Mac 保留原有本机服务例外。ATS 例外不负责路由，传输层仍强制使用 Kit。
- 加入 tailnet 不等于允许操作 Mac。现有扫码核对、Mac 批准、设备凭据、撤销和实例身份校验继续生效。
- 自建公网 relay 仍须 HTTPS；不得借私网例外接受普通公网 HTTP。旧官方客户端配置只做兼容，不作为新的默认引导；临时通道不恢复。

这一版嵌入式通路统一使用 HTTP / SSE，不启用原 WebRTC transport。任务、聊天、转录和健康资料复用现有接口；Hermes 无需改动。Tailscale 的加密边界止于两端节点，本机 loopback 只连接应用自有服务。

## 生命周期与迁移

两端的 `tailscale/` 状态目录限制为 0700 并排除备份；节点名称、密钥独立持久化。账号退出不会删除任务、草稿、转录或 Hermes 记忆。启动合并、generation 与注销保护沿用现有实现。

Mac 必须经过自己的 Kit 路由读取 `/pair/identity` 并匹配实例，才报告入口可用；15 秒租期过期后不再生成可扫码入口。地址从旧 HTTPS 改为私网 HTTP 后需重新扫码，不静默改写已有设备的连接地址；现有设备授权与资料保留。

手机后台遵循系统生命周期，不承诺常驻。连接失败后按需重建节点，复用磁盘身份；任务层继续通过幂等键和游标恢复，不在网络层盲目重放写请求。

锁屏和关闭窗口不等于系统睡眠。Mac 睡眠时 Agent 与内嵌网络不能工作；Tailscale 不会唤醒 Mac。本次未新增阻止系统睡眠行为。

## 构建与验证

先运行 `Scripts/build-tailscale-kit.sh`，用固定 XcodeGen 2.46.0 生成工程。最低版本维持 macOS 14 / iOS 18；Mac 与模拟器 SDK 含 arm64 / x86_64，手机为 arm64。保留上游 BSD 许可证，不提交生成的 framework 二进制。

1.29.2 验证：

- Swift 协议 / 配对 **37 项通过**，涵盖私网地址限制、缺少独占传输、断开后无默认 URLSession 回退、SSE 与资料请求。
- Python 入口 / 配对 **23 项通过**，涵盖私网邀请、批准前拒绝、凭据回执、租期与旧配置兼容。
- Go 生产代理回归通过，核对流式响应和请求头。
- Mac 与 iOS 模拟器使用两份真实 Swift SDK 节点、测试 control / DERP 和生产 `serveLoopbackHTTP` 验证：未开启 HTTPS Certificates、HTTP、SSE 首段先到、失效代理请求失败、重建后节点身份保持、同一任务游标恢复。Mac 自己访问自己的私网入口亦通过。
- Mac Beta 与 iPhone Release 构建通过；手机 / Watch / Widget **29 项发布包检查通过**。模拟器 ATS 与产品使用同一个 CIDR 例外，没有测试专用全局 HTTP 放行。
- 本机安装版本为 **1.29.2**，本地 ad-hoc 签名校验通过。当前真实账号登录未完成：界面提示未取得登录链接；同时观察到系统代理指向无监听的 `127.0.0.1:7890`，直连控制服务可以响应。未更改用户代理、Tailscale 账号或证书设置，不能将合成 POC 当作真实账号 / 异网手机验收。

不使用用户物理手机。真实手机蜂窝漫游、长时间后台恢复、真实账号端到端扫码仍待实测；Intel 与最低系统版本仅编译验证。完整日志、真实界面截图和结果位于任务输出 `tailnet-direct-1.29.2/`。

## 来源

- [tsnet Server API：Listen](https://tailscale.com/docs/reference/tsnet-server-api)
- [Tailscale 加密与 HTTPS 的区别](https://tailscale.com/docs/how-to/set-up-https-certificates)
- [Apple ATS 域名、IP 与 CIDR 例外](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)

## 1.29.3 按钮内加载

两端 Tailscale 登录的加载放入原按钮：原位显示系统进度指示与「正在连接」，保留按钮尺寸、正常对比度和禁用状态。删除下方重复的加载行，首次配对与设置父视图也不再追加第二个指示器；错误只在加载结束后展示。Mac 登录与检查阶段保持标题和说明不变，已连接时显示「继续」，避免已就绪还一直转圈。复用现有按钮样式，没有新增定时动画或改变账号 / 网络生命周期。

1.29.3 本机恢复观察到私网入口可用；上一版真实账号未连通的记录是当时状态，不能据此断言必须修复系统代理才能连接。手机异网配对仍未实测。

本轮 Mac 实机核对了按钮内加载、无第二个加载、完成后的继续按钮，以及暂时停止再恢复入口后状态回到可用。Mac / iPhone 构建和 29 项发布包检查通过，手机界面未使用物理设备测试。截图与精确结果保存在任务输出 `connection-loading-1.29.3/`。

## 1.29.4 连接界面状态修复

- 手机首次联系 Mac 失败后停止加载，原按钮变为「重试连接」；重试时清除旧错误，按钮内显示进度并禁止重复提交。
- 等待 Mac 确认时不额外提供重复检查按钮；配对被撤销后显示结束状态与「重新扫码」，连接验证失败显示可重试说明。
- 两端切换连接方式时取消旧登录流程；Mac 配置任务在页面退出时取消，取消本身不再被显示成错误。
- Mac 自建服务器检查复用按钮内加载，同时禁用地址编辑与重复提交。保存失败在当前页面显示一次；连接错误不再误称配对码过期，切换方式清除旧错误。

Mac Beta 与手机 Release 构建通过，手机、Watch、Widget 的 29 项发布包检查通过。专用 iPhone 模拟器首次使用 / 恢复配对 UI 测试通过；使用仅本机合成服务实际验证 503 失败 → 点击重试 → 按钮内加载且旧错误消失 → 等待确认 → 撤销后重新扫码。Mac 实机验证无效地址保存失败可见、按钮恢复可用，现有 Tailscale 配置保持可用。

当前 Mac 安装版为 1.29.4。没有使用物理手机；新的 OAuth 登录取消竞态、自建公网服务长时间检查尚未做真实账号端到端验收。截图与结果位于任务输出 `ui-audit-1.29.4/`。
