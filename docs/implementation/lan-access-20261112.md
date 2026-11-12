# 局域网直连实施记录

日期：2026-11-12。方案见 [局域网直连](../plan/lan-access.md)，待办见 [局域网直连待办](../todos/lan-access.md)。

## 结果

| 检查 | 结果 |
| --- | --- |
| `test_lan_access.py` + `test_pairing.py` | 15/15 通过（证书生成/轮换、LAN 端点校验、邀请保留、TLS 监听指纹、原有配对生命周期） |
| Mac 独立端到端 | 通过：临时数据目录与备用端口，真实 Mac Agent；`https://10.1.20.155:8869`、证书指纹、配对请求、Mac 批准、`network=lan`、`tls_sha256` 匹配、快照 200（cursor 172，8 条消息，2 个 run） |
| Android `:app:assembleDebug` | 通过；APK SHA-256 `f4e367fa90d7c89d58a61c8b2853c4a5d59decf96ed47d577aba5b1647b9ef54` |
| Android `:app:testDebugUnitTest` | 21/21 通过，包含自签名证书固定成功和错误指纹拒绝 |
| Android `:app:lintDebug` | 0 error，10 warning（版本升级与 `allowBackup` 提示） |
| Mac App 重新编译/可视流程 | **未执行**（私有 Sherpa 运行库对当前凭据 404） |
| Android 真机 | **未执行**（无设备/模拟器） |
| iOS 客户端 | **未接入**（列入待办） |

## 验证命令

```sh
# Mac 协议与证书
uv run --python 3.14 -m unittest Tests/AgentRuntime/test_lan_access.py Tests/AgentRuntime/test_pairing.py

# Android
cd Apps/AndroidApp
gradle :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
```

本轮 Mac 端到端使用已安装 App 的私有 Python 运行库和一次性临时数据目录；没有修改正在运行的 App 数据、配对库或监听端口。端到端脚本只读取会话快照的游标与计数，没有输出消息正文。

## 已知限制

- Mac 桌面端的局域网入口是源码改动，本机无法重新编译；协议层已用独立 access 服务验证。
- 局域网证书是自签名证书，客户端通过二维码指纹固定；证书轮换或 LAN IP 变化会要求重新配对。
- LAN 监听按需启动，关闭远程访问（`tunnel/stop`）时停止；当前不会在无邀请且无设备时自动回收。
- 中继模式仍不支持 Android 预览。
