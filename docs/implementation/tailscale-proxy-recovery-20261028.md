# Tailscale 代理配置与自动恢复

## 问题与证据

2026-10-28 已安装 Mac 1.39.1 的设备页显示登录超时。只读控制接口报告 Agent 在线、Tailscale 为 `needs_setup`。系统 HTTP/HTTPS 代理在本机 7890 可连接，官方 `/key` 经该代理返回 200；App 进程带有指向已关闭 7897 的大写 HTTP/HTTPS/ALL_PROXY。Tailscale 日志明确显示向 7890 的连接被嵌套进 7897 的 SOCKS dialer，返回 connection refused。

后台 Agent 和接入服务均在清理前保留的目录运行，文件存在、健康检查通过。退出并通过系统重新打开 Mac 界面后，过期变量消失，设备页与控制接口恢复 connected；两个原服务 PID 未变。该恢复验证根因，不作为最终自动化修复。

## 实现

- `momo_proxy_apple.go` 默认通过 CFNetwork 按目的地址读取当前系统配置；不再从启动 shell 决定 App 路由。移除内嵌 Go 的 ALL_PROXY 双重包装。显式手动代理或直连由 App 配置控制；loopback 保持本地。
- 系统配置查询发生在控制/DERP 连接解析时。上游重试重新读取当前代理；不添加轮询探活、扫描端口或反复重启 Agent。系统代理故障不自动改成直连。
- `TailnetProxySettings` 管理三种模式与本地原子保存。拒绝非法端口、路径、query、userinfo；损坏配置显示错误，允许重新保存恢复，不默默回退。手动代理限 HTTP/HTTPS 无认证地址；沿用现有 CFNetwork 解析边界，PAC 不支持。
- `EmbeddedTailnet.updateProxy` 保存选择并关闭网络节点，Mac 原有刷新循环按远程访问开关恢复；保持 node-name、节点状态与配对数据，不调用 logout，不重启 Hermes。
- 设置 → 通用增加「网络代理 / Tailscale」。默认只显示选择器，手动模式才展开地址，应用中的进度放按钮内；离开未应用草稿不改变连接。该入口只控制 Tailscale，模型服务代理沿用原行为。
- SDK 的 macOS、iOS、模拟器 slice 全部重新构建。新 Swift API 不能与旧 XCFramework 混用。

## 验证

- `GOMAXPROCS=3 go -C Vendor/TailscaleKit test -p 3 -c ...` 后，在 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 及小写变体均为关闭端口的环境启动测试二进制。`TestMoMo*`、`TestMedia*` 通过。真实 netns dialer 和 HTTP 客户端先遇到关闭端口，再连续改用两个本地代理成功，客户端不重建；同时验证系统选择、手动覆盖、loopback、非法地址与代理查询失败。
- `uv run --no-project python Tests/Support/test-tailnet-recovery.py`：现有连接池/恢复/登录回归，以及配置持久化、无效输入不破坏当前节点、仅网络节点重启、节点名称保留、损坏设置恢复，通过。此项使用离线 SDK double，不冒充真实登录。
- 新 framework + 真实 `EmbeddedTailnet` 编译 `probe-tailnet-login.swift`，用关闭端口覆盖六个代理环境变量：6.52 秒获得官方登录链接，二次调用复用；不登录账号、不输出 URL 或 token、结束清除临时节点。
- `Scripts/build-tailscale-kit.sh` 全平台成功；`MoMoAgentMac` Release 构建成功。
- UI 采用 standard profile，沿用现有设置字号/间距和原生 Picker、TextField、Button；没有新增动画。静态扫描 high=0；固定宽度与字号沿用 Mac 设置栏，实际截图和键盘验收另记录。未进行大字号测试（用户约定）。

## Mac 交付

- 已覆盖安装并启动 **1.39.2**，使用 Apple Development 签名和既有稳定 designated requirement。发现被替换的 1.39.1 为 ad-hoc/cdhash 签名；本次恢复稳定签名，没有清除或修改系统隐私授权。
- 实际操作设置页验证：默认跟随系统；选手动才展开地址；空地址应用给出错误并保留原连接；输入本机已确认可用的 HTTP 代理后按 Return 应用，控制接口恢复 connected；再切回系统模式并应用，设备页显示「远程访问可用」。最终保留系统模式。
- 安装前后节点名称、instance ID、已配对设备集合的脱敏摘要一致。原 Agent/接入服务 PID 均保留，`agent_online=true`；没有运行中的 admission 被打断。该操作不等于更新后台 Hermes 的代码版本。
- 默认窗口下布局和原生键盘提交已验证。设计 rubric 暂定 84/100：平台 15、结构 14、语义 14、交互 18、动效 13、辅助访问 3、性能 7。未测试 VoiceOver、其他外观和减少效果，分数不作为全矩阵通过声明；手机异地聊天也未在本轮实机验证。
- 脱敏证据保留于本机交付 `main-1.39.2/validation/`；原始登录探针 stderr 不保留（可能包含一次性登录信息）。仅保留本轮最终 SDK、已安装包、运行源码与小型验收记录，删除编译中间产物。
