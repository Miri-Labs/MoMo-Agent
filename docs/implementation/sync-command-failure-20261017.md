# 同步指令错误与迟到回调

用户报告手机显示“设备同步指令未送达：未知错误”。本轮基线为 `8804653`，交付版本为 `1.6.1`。

## 已确认的问题

- 文案来自 `PhoneReceiveCoordinator` 的 `controlTransportFinished` 分支。它是 App 的 WatchConnectivity 控制消息回调，与 Mac 安装工具报告的 RemotePairing 1001 属于不同链路。
- 原实现把一次控制消息失败写入手机的全局 `failure`，后续发送成功没有对应的清除路径，可能留下过时提示；界面只显示系统描述，未显示已取得的错误域和错误码。
- 控制消息通过后台 `transferUserInfo` 和即时 `sendMessage` 同时发送。若即时副本已应用、应用确认也已持久保存，后台副本迟到的失败仍会恢复平台退避状态。对于已从业务待办中移出的回执，后台退避标记也可能继续触发空重试。

这些代码路径可以复现误报和残留重试，不能据此认定它们就是用户这一次系统传输失败的底层原因。当前 Mac 没有采集附属设备系统日志的 root 权限；没有输入或索取管理员密码。真实 WatchConnectivity 错误码尚未取得。7001 只用于回归用例，不能当作本次故障实测值。

## 改动

- 将控制消息错误放入独立的 `syncFailure`，保留其他资料库、原音和状态错误；同一消息成功后清除自己的错误，其他消息成功不代替它恢复。
- 错误说明保留系统错误域与错误码，并说明自动重试。平台回调仍使用原有退避策略，没有添加忙循环或要求录音结束。
- `ArchiveStore.controlWasApplied` 只读取一个回执或删除操作的已持久化确认，并校验完整原消息；普通“已提交”标记不能充当应用确认。
- 手机收到应用确认或处理迟到的传输回调时，清除对应的退避状态。后台副本仍计入系统队列预算，直到其自己的完成回调到达。
- 不修改录音准入、采样、封片、删除授权及原音清理策略。

数据库查询在 Archive actor 内同步完成，没有在外部慢调用中保持事务。消息、音频及录音文本不写入新增日志；新增日志只记录错误域和错误码。

## 验证

- SwiftPM 同步、文件重放、状态和资料库对账相关测试共 50 项通过。新增用例覆盖错误码、多条失败独立恢复、系统队列预算，以及应用确认跨重启优先于迟到传输错误。
- iPhone 模拟器原生 `PhoneReceiveStatusTests` 10 项通过，实际使用原生接收协调器、Runtime 和持久化资料库；测试没有连接真实手表。专用模拟器已删除。
- 签名 Release 构建与设备交付的最终结果见本轮 `tmp_agent_output/20261017-sync-command-failure/`。
- 用户重启手表后，直接安装与开发镜像准备仍返回 RemotePairing 1001。设备安装、已安装版本与普通启动分别记录，不由编译或单测推定。

平台语义参考 Apple 的 [传输完成回调](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didfinish:error:)-8627b) 与 [WatchConnectivity 错误码](https://developer.apple.com/documentation/watchconnectivity/wcerror/code)。
