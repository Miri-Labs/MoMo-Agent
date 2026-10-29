# 手机主动导出与容量诊断

2026-10-14：P10 软件验证通过。`package-tests-13` 中 7 项导出测试和 2 项容量测试通过；`ios-tests-13` 中 3 项分享生命周期集成测试、原生分享 UI 旅程和容量 UI 旅程通过。iOS 验证环境为 iPhone 17 Pro 模拟器、iOS 27.0；同轮全部 42 项测试通过（7 项 UI、35 项集成）。原生分享页已验证两次打开与取消；保存到“文件”后的实际落盘尚未验证。

录音详情提供三种导出：转录 Markdown 与 JSON、原音分片、原音与转录。分享页使用 Apple `UIActivityViewController`，接收文件 URL，用户可以选择存储到“文件”或其他分享目标。没有新增第三方依赖。

导出是手机已收到资料的当前快照。`recording.json` 记录会话、正文版本、generation、每片音频的时间与帧范围、保留状态及 SHA-256。README 说明采集、接收、转写可能仍不完整；不会拼接音频或补齐缺口。音频文件名前缀是本次导出的收到次序，真实时间以清单为准。原音有过期或缺失时拒绝音频导出，文字仍可单独保存。

## 文件与任务生命周期

1. Archive 核对当前会话与正文版本，检查文件路径、投影和原音保留状态。
2. Archive 为音频取得内存租约，再把普通文件描述传给后台复制任务。此时不持有 SQLite 事务或文件句柄。
3. 复制任务逐片读取，缓冲区为 64 KiB；同时计算字节数和 SHA-256。句柄只存在于同步复制函数内。取消在文件边界和每个缓冲区之间检查。
4. 复制结束后，Archive 再核对来源；修订、删除或新收到的分片会使快照失效。失败或取消会删除准备中的临时目录并释放租约。
5. 系统分享读取受保护、排除备份的临时副本。原音租约已经释放，原音保留策略可继续运行。
6. 分享完成或取消时，`completionWithItemsHandler` 触发幂等清理。SwiftUI 的 `onDismiss` 只更新展示状态，不删除分享扩展可能仍在读取的文件。进程被杀后，首次启动的恢复入口清除遗留副本。

Apple 的 [completionWithItemsHandler 文档](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.property)明确将分享服务完成和用户取消作为回调边界。应用部署下限为 iOS 18，该 API 从 iOS 8 可用；此处使用 UIKit 是为了取得 SwiftUI ShareLink 未提供的完成回调。

用户存到其他位置或分享出去的副本由目标管理，不随 App 内的原音到期自动删除。清理失败会显示错误；分享完成后的副本清理可以重试。

## 容量统计口径

设置中的“本机容量”在后台遍历本机文件，读取文件长度，不读取音频或模型正文。统计原音、转录与计划文件、离线模型、索引与其他资料、临时导出副本，并显示设备当前可用空间与测量时间。模型目录由应用组合层传入；统计不会重新加载模型或执行模型 hash 校验。

这是文件逻辑字节数的快照，不包括 App 程序。数据库内的正文副本归入索引与其他资料，APFS 压缩、共享块和统计期间的写入会导致结果与系统设置中的占用不同。不根据容量推断手机可连续录制多少小时。符号链接不跟随，跳过数量会显示在页面。

模型文件已配置但尚未验证、加载时，显示“首次转写时校验并加载”。只有运行时提供真实加载成功状态，才显示模型可用。

## 已验证范围与证据

| 层级 | 结果 | 已验证行为 |
| --- | --- | --- |
| Archive 导出 | 7 项通过，`package-tests-13` | 多片字节与正文一致性、备份排除、租约阻止到期与物理删除、删除/修订/新增分片使快照失效、过期后单独导出正文、hash 失败清理、分块取消、冷启动残留清扫及目录链接拒绝。 |
| Archive 容量 | 2 项通过，`package-tests-13` | 已知字节数、类别互斥、模型目录不重复计数、Inbox 原音、外部链接不遍历。 |
| iPhone hosted | 3 项通过，`ios-tests-13` | 准备取消；SwiftUI 消失后仍保留分享文件；完成后清理与重复回调幂等；旧分享页完全关闭前阻止新导出。测试通过受控回调验证生命周期，不将它视为系统分享 UI 验收。 |
| iPhone 原生分享 UI | 1 项通过，`ios-tests-13` | 真实夹具本地转写后导出文字；打开实际系统分享页，检查“保存到‘文件’”原生操作；点击系统关闭按钮取消；再次完成同一旅程；确认正文保留且导出按钮恢复可用。 |
| iPhone 容量 UI | 1 项通过，`ios-tests-13` | 打开使用真实文件统计的容量页，检查原音、模型和设备可用空间行；核对模型尚未加载的提示；点击刷新。 |

本机证据目录为 `/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode`：

- [包测试日志](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/package-tests-13.log)与 [iOS 结果包](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/ios-tests-13.xcresult)。
- [首次原生分享截图](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/export-ui-13/718A28E8-B735-44C9-8092-6219163AAEDF.png)、[再次分享截图](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/export-ui-13/FCCCF10D-6419-490A-9542-680AB0CE514B.png)、[取消后详情页](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/export-ui-13/AA519CA1-CE35-4745-BA3A-82D8FC6ACE82.png)均已实际查看。两张分享截图都有系统保存入口，最终详情页保留转录并恢复导出入口；同目录保留对应界面层级。
- 容量 UI 用例结果为通过，但该测试未添加截图附件；[指定用例附件清单](/Users/xilanhua/WorkSpace/mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/storage-ui-13/manifest.json)为空。本次没有容量截图可供视觉复核。

初次分享旅程曾因仅匹配英文 `Save to Files` 而失败。实际系统进程显示中文保存操作；测试按观察到的原生控件标识和精确中英文标题修正后，在最终整轮通过。该修正没有改变生产分享代码或省略系统操作断言。

实际选择保存位置、保存到“文件”并重新读取目标文件的落盘校验仍未覆盖。18 小时全部分片的分享界面响应、锁屏和进程终止仍需分别验证。上述软件测试不会替代 iPhone 真机或 Watch 配对验收。
