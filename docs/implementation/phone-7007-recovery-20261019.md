# 手机 7007 连续提示修复

## 原因与边界

`WCErrorDomain / WCError.Code.notReachable`（7007）表示对端 App 暂时无法接收即时消息。Apple 的 [notReachable](https://developer.apple.com/documentation/watchconnectivity/wcerror/code/notreachable) 与 [isReachable](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable) 文档说明，配对、安装和处于通信范围内不等于始终能够即时通信；对端运行状态也影响可达性，检查后的状态仍可能变化。

[sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)) 另明确说明，手机发即时消息不会唤醒 Watch App；送达前失去可达性也会进入失败回调。因此正常生命周期变化可能引发该错误，不能把它直接视为设备损坏或丢失录音。

手机此前会把这种失败写入 `PhoneRuntime.failure` 或 `syncFailure`。关闭全局横幅仅清空展示值；下次失败或发布控制消息失败集合时又会填入，因此同一段断连反复打断操作。`LinkRetryBackoff` 原有 30、60、120、240、300 秒退避不会自动消除这个展示问题。

本轮真机在 CoreDevice 中不可用，未取得故障时的设备日志；不能据此断定最初是蓝牙、设备距离还是 Watch App 生命周期导致不可达。

## 修改

- 手机收件协调器按系统错误域和枚举值识别 7007，传输回调、同步提交与状态发布的暂时不可达保留诊断，不再写入全局错误。
- 控制消息失败集合支持筛选展示错误。7007 仍保留在失败集合中供回执核对，不会遮住另一个控制消息的真实错误。
- 保留原有发送通道、后台副本、退避、持久队列与回执规则；不把隐藏提示当作成功接收，不删除待同步录音。
- 其他错误域中的 7007，以及仅在文案中包含 “7007” 的错误仍正常提示。手表状态继续由既有状态报告与新鲜度规则展示。

## 验证记录

- 修复前在 iPhone 模拟器连续注入 25 次不可达，出现 50 次全局失败值断言失败，并覆盖了一条原音错误；测试正文完成后停止了耗时的 Xcode 失败诊断采集。原始日志：`tmp_agent_output/7007/before.log`。
- 修复后的 `PhoneReceiveStatusTests` 与 `PhoneReceiveControlFailureTests` 共 **31 项通过，0 失败**，覆盖手机收件、控制传输与退避。结果记录于 `tmp_agent_output/7007/after.log`、`after.xcresult`。
- 新增用例覆盖重复失败和关闭提示、待同步原音保留、对账响应重新入队、30/60 秒退避、混合错误展示以及严格错误域/错误码判定。
- iOS 真机目标的未签名 Release 构建成功；`verify-release-bundle.py` **29/29 项静态检查通过**，手机、内嵌手表和 Widget 均为 1.10.10，生产模型完整。证据：`tmp_agent_output/7007/release-build.log`、`release-bundle.json`。此产物未安装到真机。

版本：1.10.10。实际真机安装和设备断连恢复仍需分别验证。
