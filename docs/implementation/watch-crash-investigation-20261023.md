# 手表退出诊断（2026-10-23）

基线：`d9f4e260`。用户报告手表最近闪退。本次没有取得手表崩溃报告，不能确认退出原因，也没有进行覆盖安装或修改录音逻辑。

## 手表证据

- 开始时 `xcdevice` 和 `devicectl` 能发现 Watch SE，型号 `Watch6,11`，watchOS 26.6。读取系统崩溃目录和安装版本的两次串行请求都返回 CoreDevice 4000 / RemotePairing 1001：开发连接隧道建立超时。设备发现不代表能读取日志。
- 手机的系统诊断目录包含该手表的 `ProxiedDevice` 目录；读取元数据确认型号与系统版本一致。目录清单没有 MoMoAgent 的手表崩溃报告。复制其中的分析汇总时系统拒绝读取，未尝试更改权限。
- 上次独立读回的腕上版本是 1.19.2，记录见[安装结果](device-install-1.19.2-20261021.md)。后续 1.19.3、1.19.5 和 1.19.8 的直接安装没有成功；手机内嵌 Watch 包是否已由系统更新到腕上，仍未确认。
- 对保留的 1.19.2 Watch 安装包，读取其描述文件中的开发证书，并使用 `security verify-cert -p codeSign -R ocsp -R require -v` 验证。结果是 `CSSMERR_TP_CERT_REVOKED`；叶证书的 OCSP 结果包含 `isDefinitive=1`、`isRevoked=1`。描述文件本身到 10 月 26 日才到期，不能将证书撤销说成描述文件过期。
- 证书撤销是旧包启动失败的明确风险。由于当前腕上版本与这次退出日志未知，不能认定它就是本次闪退原因，更不能用它解释所有录音期间的退出。
- 对较新的 1.19.8 包进行要求每级证书返回有效撤销状态的校验，结果为 `revocation check not successful for each cert`。这不等于证书已撤销，也不能写成已完成当前在线验证。
- 最后一次设备查询中，手机和手表均为 `unavailable`。没有卸载应用、重置设备、清理录音或重启设备服务。

## 另行确认的手机启动超时

手机目录列出 13:00:03、13:01:41、13:02:13 三份 MoMoAgent 报告。本次成功取得并解析了最后一份，另外两份未完成内容核对。

13:02:13 报告属于 **iPhone 上的 1.19.8**，不是手表：

- Bundle 为 `com.momoagent.ios`，设备为 `iPhone18,1`。
- `EXC_CRASH / SIGKILL`，终止原因 `FRONTBOARD / 0x8BADF00D`。
- `scene-create` 超过 10 秒墙钟时限，温度状态为 `nominal`。
- 主线程位于 `getxattr → FileManager.attributesOfItem → InboxCustodian.recoverInterruptedHandoffs → ArchiveStore.init → PhoneComposition.make → PhoneBootstrap.initialize → didFinishLaunching`。

当前源码仍在启动回调中同步打开资料库；打开前还会递归配置自有目录，随后逐项恢复收件目录。这里存在历史资料增加后阻塞启动的真实问题。修复应把磁盘准备和收件恢复移出主线程，并使无页面的 WatchConnectivity 启动、页面启动及后台任务共用一次初始化；保留中断恢复和错误报告。不要靠删除收件原音或跳过完整性校验来缩短启动。

13:13:44 读取的手机接收诊断包含 10 天、5,652 条片段记录，最后一次提交为 13:06:48，待发送回执 1,432 条。这说明报告发生后仍有接收提交，不能将上述退出直接说成资料丢失或接收完全停止。待发送回执也不能当作丢失原音的数量。本轮没有修改或验收手机启动修复。

Apple 对 `0x8BADF00D` 的解释和处理原则见[启动及响应超时](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations)。报告获取方法见[设备崩溃日志](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)。

## 后续验证顺序

1. 开发连接可用后，先读腕上实际版本和完整的 MoMoAgent/Jetsam 报告，再确定属于签名拒绝、代码异常还是系统资源终止。
2. 如腕上仍是撤销证书签名的版本，用有效签名覆盖安装。保留容器、录音和配对，不卸载旧应用。
3. 分别验证打开应用、持续录音、后台运行、分片同步和重新进入。安装成功、启动成功与长时间录音稳定分别记录。
4. 手机启动阻塞单独修复并验证：无页面接收能启动；并发初始化只建一个运行时；大量未处理收件不阻塞主线程；中断恢复不丢资料或错误确认。

证据保存在忽略目录 `tmp_agent_output/watch-crash-20261023/`。设备原始报告、资料库标识和证书内容不提交到 Git。本次 Mac 语音测试的原生运行时崩溃不是 Watch 报告，不能用于归因手表退出。
