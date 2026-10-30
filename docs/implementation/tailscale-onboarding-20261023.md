# Tailscale 首选连接 · 1.27.0

> 历史记录：默认连接已由 [1.29.2 双端内嵌 Tailscale](embedded-tailscale-20261023.md) 替代。现在使用加密私网内 HTTP / SSE，无需 HTTPS / MagicDNS / Serve 配置。下文旧客户端教学不再用于 onboarding；自建公网服务器的 HTTPS 要求仍有效。

> 历史版本记录。1.28.1 已移除临时入口；当前选择、迁移与自建服务器边界见[固定连接方案](stable-remote-access-20261023.md)。以下验证保留 1.27.0 当时的事实。

本次只在 `codex/hermes-app-20261021` 实现，不合入 main。

## 用户流程

Mac 是个人 Agent 的私网服务器：保持开机、联网、唤醒并运行 MoMoAgent。手机负责采集、同步和聊天，Hermes 继续在 Mac 执行。Tailscale 解决可达性，MoMoAgent 扫码解决应用内设备授权。

首次连接放在 onboarding：

1. Mac 准备运行环境与模型；两端安装官方 Tailscale，用同一账号加入同一个网络并开启连接。
2. Mac 页面提供针对实际访问端口的 Serve 命令，复制到终端执行一次。按官方提示开启 HTTPS / MagicDNS。默认连接端口为 8767，Agent 和管理端口不对外转发；已有端口配置请勿覆盖。
3. 点击检查连接。App 只读调用官方 CLI，识别当前 DNS 名，核验持久 Serve 的 HTTPS、精确本机目标与 Funnel 状态，再用 `/pair/identity` 验证实际实例。
4. 检查通过才显示二维码；手机看完教学后扫码，两端核对数字并在 Mac 允许，之后进入聊天。

其他 HTTPS 和临时公网入口放进“其他连接方式”。首次不自动开启临时入口，Tailscale 失败不回退公网。原来使用临时 / 自定义地址的用户保留既有选择与凭据；换地址后重新配对。

## 实现范围

- 新增 `tailscale_access.py`，仅执行 `status --json` 与 `serve status --json`。官方 Mac GUI 内的 CLI 强制 `TAILSCALE_BE_CLI=1`；兼容常见 Homebrew 路径。命令有超时，不读出或展示全量设备列表和登录凭据。
- 使用实际访问端口作为 Serve HTTPS 端口，避免占用常见 443。教程使用 `--bg` 持久 Serve 配置，App 不自动执行配置、重置 VPN 或覆盖其他服务。
- 启用意图落盘；启用后在未登录、断网等状态每 30 秒重新检查，恢复后继续端点身份核验。首次未启用不会主动调用 CLI。
- 停用远程访问后拒绝后续请求、结束 WebRTC 并停止后续 SSE 转发；不会注销 Tailscale、清理 Serve、撤销既有配对或取消 Hermes 任务。已进入执行的请求继续，符合既有任务生命周期。
- 现有 SSE、游标恢复、WebRTC 与配对凭据继续复用，未引入新同步协议。手机“已连接”只是用户完成教学的声明，实际可达性仍以扫码请求成功为准。
- iPhone 的系统 VPN 共存限制在教学中说明。当前不内嵌 Tailscale，也未实现系统守护进程、开机无人登录运行和远程唤醒。

## 为什么暂不内嵌

官方 `libtailscale` 有 C / Swift 绑定，官方实验项目 Aperture Plus 展示了 iOS/macOS 纯 userspace 网络，不应把内嵌说成不可行。但这需要自己的节点登录与密钥生命周期、HTTP 代理和原生 WebRTC 路由适配。本版选官方客户端，先完成可解释、可验证的主线。

## 资料

- [Serve 命令、HTTPS 与持久启动](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [官方 macOS CLI 入口](https://tailscale.com/docs/reference/tailscale-cli?tab=macos)
- [其他 VPN 共存限制](https://tailscale.com/docs/reference/faq/other-vpns)
- [libtailscale](https://github.com/tailscale/libtailscale)
- [Aperture Plus 实验示例](https://github.com/tailscale/aperture-plus)

## 验证

- Mac Debug 构建通过；iPhone Release（含 Watch / Widget）构建通过，29 项静态包审计全部通过，版本均为 1.27.0。
- 连接、转录投递相关 17 项 Python 测试通过，其中 6 项针对 Tailscale；WebRTC 相关 8 项通过，4 项需外部 native probe / TURN 的互操作测试按条件跳过。
- iPhone 17 / iOS 27 默认字号 onboarding UI 测试通过，覆盖教学前无扫码、继续扫码、重开恢复、其他连接方式与稍后配对。实际截图已检查，无裁切。
- Mac 用独立合成状态服务检查真实 SwiftUI 页面，核对三步教学、未登录提示、折叠的其他方式与返回；此项是界面验证，不代表真实 Tailscale 连通。
- 本机实际 CLI 只读检查返回无法联系 Tailscale，正确停在 needs_setup。未替用户登录、修改系统 VPN、运行 Serve 配置或使用用户手机。真实账号登录、手机异网 HTTPS / SSE、Mac 重启后回连仍待实际网络验收。
- 临时 iPhone 模拟器已关闭并删除。保留截图、日志、包审计与本版构建产物，清理本轮构建缓存。
