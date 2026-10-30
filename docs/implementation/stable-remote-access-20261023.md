# 固定连接：Tailscale 与自建服务器 · 1.28.1

> 历史记录：默认连接已由 [1.29.2 双端内嵌 Tailscale](embedded-tailscale-20261023.md) 替代。现在使用加密私网内 HTTP / SSE，无需 HTTPS / MagicDNS / Serve 配置。下文旧客户端教学不再用于 onboarding；自建公网服务器的 HTTPS 要求仍有效。

用户决定移除临时通道。本次仅在 `codex/hermes-app-20261021` 开发，覆盖旧方案中 localhost.run、临时公网入口与升级保留临时 provider 的描述。

## 两条路径

| 选择 | 用户准备 | App 负责 |
| --- | --- | --- |
| Tailscale（推荐） | 两端安装官方客户端、登录同一网络；按教学开启 Mac Serve | 读取状态、核对私网 HTTPS 与本机服务、检查实例，再扫码授权 |
| 自建服务器（高级） | 固定域名与 HTTPS、服务器转发服务、Mac 侧长期运行的连接器 | 接收固定 HTTPS 根地址、检查实例，再使用相同扫码、鉴权与 SSE 协议 |

Tailscale 失败保持原连接方式，不自动回退公网。手机选择“我的 Mac 使用自建服务器”后直接扫码，无需为这条路径安装 Tailscale。首次连接仍在 onboarding，日后从设置管理。

## 自建 relay 的明确含义

这里指 **HTTP / SSE 连接入口的转发服务**，不是把 Hermes 放在 VPS，也不是单独一个 TURN 服务器。可复用 frp 等成熟连接器，无需本版新增自研中继协议。

```text
手机 ── HTTPS ──> 固定域名 / 用户的服务器
                          │  转发
                    Mac 主动建立的连接
                          │
                  Mac Access Service（loopback）
                          │
                    Hermes / 资料服务
```

建议部署形态：公网服务器提供域名、有效 HTTPS 证书与转发；Mac 连接器主动连接服务器，转发到 App 展示的 `localAccessURL`（默认 `http://127.0.0.1:8767`）。公网服务器仅配置一个反向代理指向 Mac 的 loopback 地址无法打通两台机器，必须有这段可达链路。

本版 App 不部署 VPS、不安装 frp、不接管连接器的启动。用户负责固定入口及连接器；已支持的 `external` provider 保持通用，不绑定服务商。官方固定托管入口在协议兼容时仍可填写，产品只呈现这一个高级入口，不增加第三套流程。

部署时仅转发 Access Service；保留 `Authorization`、`Idempotency-Key` 和 `Last-Event-ID`，支持 SSE 长连接并关闭缓冲、缓存、跳转和额外网页登录。Mac 连接器到服务器也需启用并校验 TLS 和认证。若 HTTPS 在服务器终止，该服务器可接触转发内容，不能称作手机到 Mac 的端到端加密。

WebRTC 是已有可选传输。TURN 配置和 Tailscale 自有的中继机制不等于上述应用入口；不因移除临时 HTTPS 通道而删除现有 WebRTC 能力，也不承诺任意自建 HTTPS 入口自动承载 WebRTC。聊天继续可经 HTTPS / SSE 工作。

## 升级与恢复

- 删除临时 SSH 连接器及所有首次 / 设置入口；配置接口拒绝 `temporary`。
- 支持的 `tailscale` / `external` 配置保留地址和启用意图。
- 遇到旧临时或未知 provider，关闭远程访问，展示重新选择提示。后台不启动 Tailscale，不建立公网通道。直到用户主动选择或开启受支持方式才写入新配置，重启前后的提示保持一致。
- 配对授权、工作区身份与 Agent 任务不删除。旧地址失效后手机需要重新扫码取得新入口；运行中任务按原 run ID 恢复，SSE 按原游标继续，提交幂等键保持不变。
- 历史 POC 与报告保留测试时事实，不能作为当前仍提供临时通道的说明。

## 在线条件与嵌入路线

Mac 是实际执行服务器，锁屏 / 屏幕关闭不等于系统睡眠。要随时接收任务，Mac 的系统和 MoMoAgent 服务必须运行；Tailscale 或自建 relay 都不能让睡眠中的 Hermes 继续计算。本次未更改用户的睡眠设置，也未实现远程唤醒或系统守护进程。

Tailscale 应用内嵌入仍是独立研究项。本版继续采用官方客户端与 onboarding 教学；未来可评估先嵌入 Mac 的 TailscaleKit，保持手机官方客户端，再考虑双端内嵌。不会把本次删除临时入口扩展成 VPN SDK 改造。

## 验证范围

- 19 项连接、Tailscale 与配对测试全部通过：旧配置重复启动保持关闭；既有授权保留；临时接口返回 400 且不破坏当前入口；入口切换后任务身份、幂等键和 SSE 游标保持一致。
- Mac Debug、iPhone Release 构建通过；实际保留的 1.28.1 手机包及内嵌 Watch / Widget 通过 29 项静态审计。
- 本次未运行界面截图验收、未使用真实手机、未替用户登录 Tailscale，也未部署公网自建服务器；不把本地协议测试表述为公网验收。
- 证据和最新构建保留在本任务 `outputs/stable-access-validation/`；完成后清理本轮 DerivedData 及被替代的旧安装包。

参考：[Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)、[frp 架构与协议](https://gofrp.org/en/docs/overview/)。


后续：1.29.0 将新用户默认路径升级为[双端内嵌 TailscaleKit](embedded-tailscale-20261023.md)。本文件保留 1.28.1 的历史验证，不将它当作内嵌实现的验收。
