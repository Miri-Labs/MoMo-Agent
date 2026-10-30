# iPhone 启动失败与签名检查

2026-10-19 晚，用户报告手机端打开后立即退出。设备实际安装的是 1.10.5；尚在开发的首页布局修改没有安装到手机。

## 现场证据

- 普通启动、连接控制台启动及暂停等待调试启动，均返回 CoreDevice 10004：无法取得启动进程号。进程列表中没有 MoMoAgent。
- 手机已解锁。系统报告列表没有此次 MoMoAgent 崩溃报告；20:09:31 的 Jetsam 报告终止对象是 searchd，不能用它证明 MoMoAgent 内存超限。
- 原安装包在 Mac 上通过 `codesign --verify --deep --strict`。嵌入的描述文件有效期为 10 月 17 日至 10 月 24 日，包含该手机。
- 用同一个已保留的安装包原位安装时，手机明确拒绝：`MIInstallerErrorDomain 13`、`0xe8008018`，`The identity used to sign the executable is no longer valid.`

Xcode 的证书管理界面进一步确认：旧证书标记为 `Revoked`；10 月 19 日由 Mac mini 创建的有效证书显示 `Not in Keychain`。这台 Mac 没有该证书的私钥。首次刷新签名返回 `No Accounts`；用户随后完成 Xcode 重新登录。

因此，已确认的问题是手机不再接受当前包的签名身份。本地完整性校验与描述文件日期检查不能代替设备上的有效性验证。上述证据没有说明是谁或哪个任务吊销了旧证书，不据此归因于某次代码修改、VPN 或录音资料库。

诊断保留在任务目录 `tmp_agent_output/20261019-phone-launch-crash/`。其中系统日志和设备资料仅供本地诊断，不提交到仓库。修复过程保留应用容器，不卸载应用、不删除录音或聊天。

## 后续安装检查

用户已明确授权停用 Mac mini 的证书，改用当前 Mac 的签名。登录后，移出已备份的三个旧描述文件，使用 `-allowProvisioningUpdates` 刷新。Xcode 于 20:42 为当前 Mac 创建了新签名身份（SHA-1 前缀 `B62C2FDE`），并为手机、手表及 Widget 签发了包含新身份的描述文件；随后 Release 构建成功。新身份的私钥由本机生成和持有。界面工具暂时无法读取 Xcode，尚未独立确认 Mac mini 证书的吊销状态。

最终 1.10.8 Release 构建成功，实际产物检查 29 项通过，手机和手表包均通过严格签名校验。交付使用冻结的 `Products-Verified` 产物，避免后续构建覆盖安装来源。

手机原位安装成功，设备独立查询返回 1.10.8。普通启动返回 PID 16428，后续进程查询仍为同一 PID，未重现原先无法启动的问题。启动后的接收诊断生成于 21:04:11：资料库身份保持不变，按日期与来源逐片对比，与安装前的 2,704 个片段一致；其中 10 月 18 日为 852 片。此检查确认接收档案保留，未逐一重新解码全部音频。待回执数仍为 752，本次安装检查不等于同步积压已全部清空。

证据：`phone-install-1108-retry.json`、`phone-version-1108.json`、`phone-launch-1108.json`、`phone-processes-verified.json`、`receive-preservation-check.json`。均保留在上述本地诊断目录。

## 手表安装结果与重试依据

最初两次安装明确返回 CoreDevice 10003（设备锁定）。用户解锁后，第一次连接返回 RemotePairing 1001（建立开发隧道超时）。该失败发生在包传输前，与应用内 WatchConnectivity 错误码不同。

随后沿用当天 18:32 已成功的流程：对同一手表直接安装独立的 Release Watch 包，单个安装请求上限 600 秒，不并行发起手表探测，也不重置配对或重启连接服务。21:04:37 开发隧道建立；21:06:11 调试镜像挂载成功；21:06:17 系统开始应用安装。最终安装返回成功，设备安装序列为 1008。

独立查询腕上版本为 1.10.8，普通启动成功并返回 PID 478。证据为 `watch-install-unlocked-retry.json`、`watch-version-1108.json`、`watch-launch-1108.json` 及 `watch-install-system-progress.log`。本次复用已有配对完成更新；不能把单次重试成功归结为某个网络设置必然有效，也不将安装成功等同于全天同步或续航验收。
