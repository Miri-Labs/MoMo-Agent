# C109：当前手表状态的隔离范围

本轮源码以 `origin/main` 的 `6899ea8` 为基线，位于独立分支 `codex/watch-status-scope`。实现已保存；本任务未运行 Swift 包、Xcode 构建、模拟器或原生测试，以下测试均待主线程统一执行。

## 系统身份与生命周期依据

Xcode 27 的 iPhoneSimulator SDK `WatchConnectivity.framework/Headers/WCSession.h` 提供以下契约：

- 第 72–73 行：`watchDirectoryURL` 专属系统当前选中的 Watch，切换时 URL 改变；卸载或取消配对后该目录会在下次启动时删除；未安装 Watch App 时为 nil。
- 第 45–46 行：激活完成后才能使用有效的 session 属性。
- 第 136–139 行：delegate 回调位于同一个非主线程串行队列。
- 第 148–152 行：进入 inactive 后旧 Watch 仍可产生后台回调；deactivate 发生在旧 Watch 全部回调之后，此后才激活新 Watch。

该目录是本机系统提供的选中设备命名空间。代码不从音频收件箱中的 device ID、状态时间或全库最新行推断当前设备。

## 实现

`WatchConnectivityTransport` 在 delegate 回调边界同步记录选中目录、激活 epoch 和递增顺序号，再投递到 MainActor。状态和状态解码错误都携带这份本地票据；音频文件、控制消息、收件确认及删除协议没有变化。

`PhoneReceiveCoordinator` 的当前显示只接受可用目录下当前 epoch 的新票据。切换、未激活、未配对、未安装或目录未知时，立即清除旧显示。旧票据仍可经 Archive 原有身份和 revision 校验保存历史，但不能写当前设备缓存、替换当前显示或改当前错误提示。无 scope 的历史输入也不影响当前状态。

每个系统目录内保存一份按 library ID 命名的原子状态文件。读取限制为普通非符号链接文件和协议大小上限；恢复后仍经 Archive 校验，始终显示为旧状态，重复回调不会刷新到达时间。有效新 revision 才能成为新观察。没有目录缓存时保持等待，不查询全库最新状态作为替代。

Archive 的新增 `receiveWatchStatusReport` 与原 bool API 共用一次验证及写入逻辑，返回经过确认的 observation；无录音的 idle 状态可展示但不制造录音、收据或删除权限。当前状态依旧受接收资料库、来源、版本、已删除会话门槛约束。

在 Archive await 前保存本地删除代次，成功和失败返回都重新核对；本机删除完成时即使还没有可见状态，也会推进代次，阻止旧 continuation 重显或重写缓存。缓存失败返回还须确认没有更新的 live 回调。此门槛已经独立静态复核，未声称实际调度竞态测试通过。

## 待执行验证

新源码和 hosted 测试文件需要重新生成 Xcode 工程。执行由主线程使用其既有依赖和专用设备安排。

- 包 `SelectedWatchContextTests`：2 例，切换前的票据不会因稍后选择而重标，inactive 后的旧回调没有当前权限；重新激活和不可用状态失效。
- 包 `ArchiveStatusTests`：保留原 5 例，新增 2 例验证 accepted observation 的缓存/重复/版本/删除门槛和无会话 idle 不授予收据权限。
- 宿主 `SelectedWatchStatusIntegrationTests`：3 例，真实 Archive 收件后进行两设备切换及确定性乱序投递、每目录重启恢复及 freshness、旧 scope / 无 scope 错误隔离及删除恢复拒绝。两设备均为隔离目录和协议 fixture，非真实 WC 配对切换。
- 宿主 `PhoneReceiveStatusTests`：保留 5 个原行为用例，当前错误恢复用例改走明确 scope；历史缓存用例仍验证不推动对账或收据。
- 宿主 `WatchStatusPresentationTests` 与 UI `PhoneWatchStatusTests`：现有陈旧/录音/静音/导航用例。DEBUG fixture 使用同一 scope 接线，未增加生产假状态入口。

仍需区分上述软件状态边界与真实双 Watch 切换、系统回调时序及跨设备 WatchConnectivity 交付；本轮未操作设备，也不把临时目录模拟称为真机配对验收。
