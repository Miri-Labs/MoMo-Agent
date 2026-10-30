# Tailscale 登录链接失败修复

## 根因与复现

2026-10-27，在已安装的 MoMo Agent 1.36.0 上读取到：

- Mac Agent 本身在线；内嵌 Tailscale 为 `needs_setup`，尚无远程入口。
- 19:20:11（北京时间）Tailscale 注册请求返回 `connection attempts aborted by context: context deadline exceeded`。
- 系统已配置 HTTP/HTTPS/SOCKS 代理。普通 HTTPS `/key` 请求直连及经代理均成功，不能据此推断 Tailscale 控制协议可用。
- 当前固定的 Tailscale 1.104.1 默认代理解析读取进程环境；没有 macOS 系统代理解析实现。GUI 启动的内嵌节点未使用系统已配置的代理。

使用旧 XCFramework、独立临时节点与相同网络做对照，均未登录账户：

| 路径 | 真实结果 |
| --- | --- |
| 原 SDK，不注入进程代理 | 35.10 秒内未得到登录 URL |
| 原 SDK，显式使用系统已有的代理地址 | 7.28 秒得到登录 URL |
| 新 SDK，无进程代理，自动读取系统设置 | 3.56 秒、2.76 秒得到登录 URL |
| App 的实际 `EmbeddedTailnet.loginURL()` + 新 SDK | 4.55 秒、6.84 秒得到登录 URL；再次调用复用同一 URL |

第二个问题是 App 只轮询 `15 × 300 ms` 后报错。上游 `StartLoginInteractive` 只负责发起请求，登录 URL 异步返回；7.28 秒的成功请求也会被原 UI 判为失败。上游契约见 `tailscale.com@v1.104.1/client/local/local.go` 的 `StartLoginInteractive` 注释，以及 [控制协议实现](https://github.com/tailscale/tailscale/blob/v1.104.1/control/controlhttp/client.go)。

## 改动

- `Vendor/TailscaleKit/momo_proxy_apple.go`：通过上游 `tshttpproxy.SetProxyFunc` 接入 CFNetwork 系统代理查询。每次解析读取当前设置，遵循系统绕过列表；显式进程代理、`NO_PROXY`、loopback 绕过保持优先。
- 仅影响 Tailscale 的出网 HTTP 传输（控制、DERP 等）；手机到 Mac 的业务流量仍经过内嵌 tailnet，不增加普通公网回退。
- 支持手动 HTTP、HTTPS CONNECT、SOCKS 配置。本机并未启用 PAC；PAC 自动脚本暂不支持，会返回错误，不悄悄绕过代理。没有读取 Keychain 中的代理凭据。
- `EmbeddedTailnet.loginURL()`：最多等待 60 秒，但 URL 到达立即返回；复用已发出的 URL；区分网络超时、管理端设备审批和无法打开认证窗口。关闭页面/替换节点后，旧请求不能继续返回结果。
- `Tests/Support/test-tailnet-recovery.py` 增加真实业务类上的延迟登录、重复打开、超时、已有登录、设备审批、取消与节点替换回归。
- `Tests/Support/probe-tailnet-login.swift` 提供可重复运行的真实 SDK 登录链接探针，独立临时目录，无自动账户登录；仅输出布尔结果与耗时，不输出 URL 或 token。

## 验证命令

在本任务工作树执行：

```sh
cd Vendor/TailscaleKit
go test ./... -count=1
cd ../..
bash Scripts/build-tailscale-kit.sh
uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent/Agent/runtime/venv/bin/python' Tests/Support/test-tailnet-recovery.py
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Users/syh/Library/Application Support/MoMoAgent/Agent/runtime/venv/bin/python' -m unittest discover -s Tests/AgentRuntime -p test_embedded_tailscale.py
```

Go 全包测试通过；Swift 登录与原连接恢复回归通过；Python 配对/私网入口测试 3 项通过；完整 XCFramework（macOS、iOS、iOS Simulator）构建通过。Mac 与 iPhone Release 整包编译均 `BUILD SUCCEEDED`（未签名、未安装）。

整包编译使用 `xcodebuild -project MoMoAgent.xcodeproj -configuration Release CODE_SIGNING_ALLOWED=NO build`，分别指定 `MoMoAgentMac / generic/platform=macOS` 与 `MoMoAgent / generic/platform=iOS`。DerivedData 放本工作树 `tmp_agent_output/tailscale-login/`。不要使用 `/tmp` 作为本工程 SPM 下载目录：当前 Xcode 在解包 ONNX 二进制时混用 `/tmp` 与 `/private/tmp`，导致合法 framework 符号链接被判断为越界；本轮曾复现此工具链错误，改为工作树内实际目录后继续编译。

原生探针编译需要：新 XCFramework 的 macOS slice、`EmbeddedTailnet.swift`、`TailnetDiagnostics.swift`、`MoMoAgentClient` 模块与 `Tests/Support/probe-tailnet-login.swift`。运行时清除 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 及小写变体，以确认实际读取系统设置，而不是由终端环境掩盖问题。stderr 不应直接展示，SDK 可能记录一次性登录信息。

## 集成与验收边界

分支 `codex/tailscale-login-fix-20261027`，基线 `09a4606c`。修改独立于正在进行的 Mac 权限界面任务。

集成时必须重新运行 `Scripts/build-tailscale-kit.sh` 或使用本分支已构建的 XCFramework；仅编译 Swift、继续使用旧的缓存 XCFramework 无法修复系统代理问题。

本次没有替换正在运行的 App，没有重启用户服务，没有修改系统代理、现有 Tailscale 身份或配对记录。真实测试验证到官方登录 URL 成功生成；账户授权、扫码配对、手机异地通信仍需在集成后的 App 上验收，不能将探针成功当作双端配对成功。
