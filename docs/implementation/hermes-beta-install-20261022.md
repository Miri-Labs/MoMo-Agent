# Hermes Beta 本地安装（1.23.1）

用户要求在 Mac 安装当前 Hermes 分支，并在已有正式版的 iPhone 上并排安装 Beta。

## 构建方式与隔离

新增 Release 类型的 `Beta` 配置和 `MoMoAgentBeta` / `MoMoAgentMacBeta` scheme，仍使用现有 target、源码与依赖。正式版的 Debug / Release 标识保持原值，版本统一来自 `Config/App.xcconfig`，本次内部构建递增至 100。

| 身份或存储 | 正式/原开发版 | Beta |
| --- | --- | --- |
| iPhone Bundle ID | com.momoagent.ios | com.momoagent.ios.beta |
| Mac Bundle ID | com.momoagent.mac.dev | com.momoagent.mac.beta |
| Watch Bundle ID | com.momoagent.ios.watchkitapp | com.momoagent.ios.beta.watchkitapp |
| Widget Bundle ID | com.momoagent.ios.watchkitapp.widget | com.momoagent.ios.beta.watchkitapp.widget |
| Watch App Group | group.com.momoagent.watch | group.com.momoagent.watch.beta |
| Widget deep link | momoagent | momoagent-beta |
| Mac 数据目录 | ~/Library/Application Support/MoMoAgent/Agent | ~/Library/Application Support/MoMoAgent Beta/Agent |
| Mac 本地基础端口 | 8765 | 8775 |

手机后台任务标识从实际 Bundle ID 派生，并与包内声明一致。Watch 配对的 companion ID、组件共享容器、Widget kind 和控制链接随配置隔离。链接解析仍保留原有 generation / session 验证。手机沙盒、默认 Keychain access group 和 UserDefaults 随独立应用标识隔离，未添加共享凭据权限。Gmail 教程显示当前包自己的 ID。

## 验证和安装状态

- Mac Beta、已签名 iOS Beta 与原正式配置 Release 回归构建成功；原正式包的 29 项发布检查也通过。
- 发布包审计支持显式 `--variant beta`，默认仍严格检查原正式版标识；Beta 29 项静态检查通过。
- 发布审计自测 23 项通过；Widget 契约 7 项通过，包括两种 scheme 互相拒绝。
- 单独核对手机、Watch、Widget 的代码签名、签名 entitlement、App Group、companion 关系、版本和实际描述文件。
- 当前使用个人开发签名，三个 Beta 描述文件有效至 2026-10-29，不是 TestFlight 分发。
- Mac 安装于 `/Applications/MoMoAgent Beta.app`，实际启动并完成隔离运行环境准备，停在“连接模型”，等待用户填写模型服务。
- Mac 当前为开发 Beta，`MoMoRepositoryRoot` 仍引用本机 Hermes worktree；不能移走该源码目录，尚未制作可搬到其他电脑独立运行的发布包。
- 手机目前在 CoreDevice 中为 unavailable，安装前查询失败；未卸载、替换手机正式版，也未声称 Beta 已安装到手机或手表。接通手机后仅对独立 Beta ID 安装并验证。

签名安装包保存到当前任务 `outputs/MoMoAgent-Beta-1.23.1.ipa`。该开发签名包仅针对描述文件列出的设备，不能作为任意手机直接下载安装的公开链接。
