# Hermes 合入 main 与正式版升级 · 2026-10-27

用户明确要求：Hermes 全部合到 main；手机以 Hermes 为主，设置借鉴 main 布局与开关；删除手机 Beta，不备份 Beta 数据；正式手机与手表覆盖升级。未授权将 Beta 私有资料自动迁移进正式版，不改动现有 Mac Beta 进程。

## 合并取舍

- 基于 main `12237581` 合入 Hermes `839d1e62`。手机仅保留 Mac 远程执行、TailscaleKit、聊天、转录、记忆/健康资料同步，移除 main 恢复的本地 Pi 及对应过时测试。
- `MoMoRecording`、`MoMoArchive`、`MoMoSpeech`、手机与 Watch Application 录音/接收/处理源码与合并前 main 完全一致。保留后台过期时新到分片、采样边界、省电及连续转录修复。
- PhoneRuntime 保留 Hermes 生命周期；接入 main 的转录历史维护、过时模型缓存回收和 `continuousArchive: true`。
- 设置：Mac 连接主卡，通知/记忆分组、健康/储存空间、高级转录设置；通知开关只在真实配置成立时可用。存储统计采用 main 新字段。
- 正式版 APNs topic 使用 `com.momoagent.ios`；Beta 仍独立。网关与 Mac 配置支持显式 topic，缺省兼容旧 Beta；跨 topic 注册拒绝。

## 本地交付与限制

初次安装版本 **1.35.0（147）**；用户随后要求删除配对说明，补丁版 **1.35.1（148）**，正式手机 `com.momoagent.ios`，Watch `com.momoagent.ios.watchkitapp`，widget `com.momoagent.ios.watchkitapp.widget`。

个人开发团队签名不支持 Push Notifications。默认发布配置保留 APNs，当前本地安装通过手机专用 `MoMoAgentLocal.entitlements`（HealthKit）和 `MOMO_PUSH_ENVIRONMENT=disabled` 构建。没有部署通知服务、读取/创建 APNs 私钥，系统推送仍不可用。后续配置见 [APNs 清单](apns-setup-checklist-20261027.md)。

手机原正式版采用覆盖安装，未卸载、未删除其录音/转录目录。Beta 已按用户要求删除，未保留其备份。正式版与 Beta 为不同身份；正式版需要自己的 Mac 配对，不能继承 Beta Keychain 凭据。

## 验证

证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/hermes-main-20261027/`。

- `swift test --package-path Packages/MoMoAgentAgentClient --scratch-path /tmp/momo-main-client-tests`：105 项通过。
- `swift test --package-path Packages/MoMoAgentKit --scratch-path /private/tmp/momo-main-kit-tests`：全部测试目标通过；未提供模型的普通轮次按既有规则跳过需模型用例。
- 提供 main 锁定 VAD v6.2.3 / SenseVoice 与真实公开音频 fixture 后，`--filter 'SherpaNativeBatchTests|CompleteCoverageTests'`：13 项通过，含跨物理分片、连续输入、重建恢复、静音覆盖及 Core ML 对齐。首次缺少 `test_wavs/zh.wav` 的环境错误已在独立 fixture 目录修正，没有改测试断言。
- Python `test_desktop_control test_conversation_events test_personal_agent test_push_notifications test_pairing`：58 项通过，含新增正式 APNs topic 校验。
- `MoMoAgentThroughput` 模拟器：PhoneReceiveStatus、BackgroundGrantLifecycle、ArchiveExportLifecycle、PhoneSpeechSettings、AutomaticBackgroundSubmission，43 项通过。
- `MoMoAgentRemote` 默认字号未配对设置流程：1 项通过，检查主入口、扫码与手动配置渐进披露。
- 手机 Release 签名构建、内嵌 Watch/widget、Mac Release 构建均通过；Mac 只构建，未安装/重启。
- `verify-release-bundle.py` 和 `codesign --verify --deep --strict` 均通过。初次查出旧 Models symlink 的 VAD 哈希不匹配，改为 main 锁定模型目录后重建通过；没有降低或绕过哈希检查。

实际构建：

```sh
xcodebuild -project MoMoAgent.xcodeproj -scheme MoMoAgent -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/momo-main-release-20261027 -clonedSourcePackagesDirPath /Users/syh/Library/Developer/Xcode/DerivedData/MoMoAgent-hjpgcgoaxtzeszdeeexelycflvge/SourcePackages -disableAutomaticPackageResolution -allowProvisioningUpdates MOMO_PHONE_ENTITLEMENTS=Apps/iPhoneApp/Resources/MoMoAgentLocal.entitlements MOMO_PUSH_ENVIRONMENT=disabled build
```

## 设备验收

- iPhone：设备清单已核对正式版 1.35.0/147；Beta 不再存在。自动启动先被锁屏阻止，用户随后已解锁并打开，已读到正式版运行进程。1.35.1/148 删除配对页多余说明，实际更新结果记于交付目录。
- Watch：已附随手机安装包交付，但独立安装遇 CoreDevice 4000 / RemotePairing 1001；重试结果单独追加。不能将内嵌成功写成手表实机升级成功。
- 本轮未验收跨网络屏幕接管、后台锁屏消息回补、实际 APNs alert 或全天录音能耗；前述测试不替代这些实机场景。
