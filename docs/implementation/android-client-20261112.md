# Android 客户端预览切片实施记录

日期：2026-11-12。范围与验收见 [Android 客户端（预览切片）](../plan/android-client.md)，待办见 [Android 客户端待办](../todos/android-client.md)。

## 结果

| 检查 | 结果 |
| --- | --- |
| `gradle :app:assembleDebug` | 通过；`com.momoagent.android`，versionName `0.1.0`，versionCode 1，minSdk 26，targetSdk 35，APK 约 35 MB |
| APK SHA-256 | `1efa141fda0475168c4e7acd058b71a82d6669391935adaf805fd634e2589c3a` |
| `gradle :app:testDebugUnitTest` | 12/12 通过：配对码与连接身份 10 项，HTTPS 快照与 SSE 消息流 2 项 |
| `gradle :app:lintDebug` | 0 error，8 warning（targetSdk/compileSdk 可升级、OkHttp 与协程/序列化有新版本、`allowBackup` 弃用提示） |
| 真机或模拟器配对 | **未执行** |

产物与报告副本在忽略目录 `tmp_agent_output/android/`。

## 环境与说明

- 本机构建使用系统 Gradle 8.14.3、JDK 21、Android SDK Platform 35、Build Tools 35。仓库内 wrapper 指向 Gradle 8.14.7；本机未通过 wrapper 重新下载发行包。
- OkHttp 固定 4.12.0。`okhttp` 5.5.1 的 Android 构件要求 `compileSdk 37`，当前切片保持 35；升级 AGP/SDK 链属于后续工作。
- `EncryptedSharedPreferences` 在 security-crypto 1.1.0 已弃用，直接 Keystore 实现列入待办。
- 明文流量默认关闭，仅对 `localhost` 与 `127.0.0.1` 放行回环 HTTP；远程 Mac 必须使用 HTTPS。
- 运行中的 Mac 实例为 0.5.8（`com.momoagent.mac.dev`），access `/status` 返回 503，说明远程访问未开启；本轮未做扫码配对端到端。
- 本机没有 Android 设备或模拟器。构建、单测与 lint 通过不等于端到端通过。
