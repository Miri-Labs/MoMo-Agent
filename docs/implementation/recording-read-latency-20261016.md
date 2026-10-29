# 录音读取耗时修复（2026-10-16）

## 原因与改动

- 资料刷新、文件对账、投影检查共用 `inspectRecordingFiles`。原实现连未修改的 JSON/Markdown 也重新解析，并对每个段落遍历全部原文；Markdown 来源检查和录音 manifest 身份检查也存在同类重复查找。
- 未修改的投影直接与本次读取的权威正文比较；有修改的内容通过 ID 索引校验。保留来源、版本、重复 ID、路径和恢复确认的检查，不添加跨版本或跨文件的缓存。
- `recordingFileIssues(sessionID:)` 支持只检查当前录音；引用跳转的 `LibraryModel.ensureRecording` 使用此路径。
- 时间线每次读取只检查一次各音频文件是否存在，逐段复用结果；段落去重改用集合。

## 验证

- 相同 Mac、Debug 构建、同一份 4,000 段样本，独立执行 `recordingFileIssues`：修改前 **3.973 s**，修改后 **0.050 s**。这是文件检查耗时，不代表真机打开页面的端到端耗时。
- 本地最小 SwiftPM 验证包直接引用仓库的 MoMoContracts/MoMoArchive 源码和全部归档测试，避免下载无关语音/Agent 依赖。**132 个测试、23 个 suite 全部通过**；并发回归中的 4,000 段检查为 0.238 s。
- 新增回归覆盖长文不发生误修订、长 Markdown 修改可导入、单条检查范围、删除后不可见、JSON/Markdown 来源帧篡改被拒绝。既有迁移、移动目录、损坏文件、冲突、播放和时间线测试通过。
- `LibraryModel.swift` Swift 语法检查及 `git diff --check` 通过。性能验证未测量真机打开页面的端到端耗时；设备安装核验见下文。

## 集成状态

修复 `48d7ac7` 与两端 build 3 版本号提交 `6a2d35e` 已快进合并到本地 main。

- 基于 `6a2d35e` 的 iPhone Release 签名构建成功，包含相同 build 3 的 Watch App，完整签名校验通过。
- iPhone 覆盖安装成功，设备查询读回 `com.momoagent.ios` **1.0 (3)**，远程启动成功。
- Watch 首次安装遇到另一个系统安装协调任务占用（IXErrorDomain 48）。用户保持两端解锁后重试成功，设备查询读回 `com.momoagent.ios.watchkitapp` **1.0 (3)**。手表重启恢复开发连接后，本轮再次直接查询两端，均确认 **1.0 (3)**，并分别远程启动成功。未将远程启动计作真机波形、唤醒或录音验收。
- 构建、安装回执、两端版本查询及二进制 SHA-256 在 `tmp_agent_output/recording-read-deploy-20261016/`，产物在 `DerivedDataRecordingRead20261016/Build/Products/`。
- 本轮补充版本查询、启动回执与汇总位于 `tmp_agent_output/watch-waveform-20261016/`，汇总文件为 `build3-devices-verified.json`。
- 首次 Git HTTPS 推送超时后重试成功，`7ec9f2d` 已推送到 `origin/main`，随后 fetch 成功。
