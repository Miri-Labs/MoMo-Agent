# 聊天 Agent 持续后台执行

本轮在独立分支 `codex/chat-agent-background-20261019` 实现聊天后台授权。发送、重试和重新生成均在用户点击后、首次异步准备前申请。后台授权属于本轮任务，切换会话或进入空白首页不结束正在运行的任务。

## 生命周期

- iOS 26 及以上申请 `BGContinuedProcessingTask`，系统槽位繁忙时排队；更早系统使用有限的 UIKit 后台授权。UIKit 授权同时衔接 continued 任务的调度等待；continued 任务接管后立即释放短时授权。
- 每次用户操作注册唯一的具体标识，Info.plist 和 `project.yml` 同步声明 `com.momoagent.ios.assistant.continued.*`。沿用 `ContinuedBackgroundSubmission` 的身份和迟到回调隔离逻辑；iOS 27 使用主线程外的异步提交接口。
- 正常结束以整轮模型、工具执行和最终状态读取完成为准。任务完成时取消本轮尚未交付的系统请求；迟到的交付不能启动或重放 Agent。
- 用户停止或系统到期时，先关闭本轮执行，等待 Agent 的持久停止和提交清理，再释放授权。不同会话互不取消；旧回调不能影响新的用户操作。原有提交身份、已保存的回复、工具结果和未提交草稿的恢复逻辑继续生效。
- 活动状态仅报告本轮真实收到的输出字节及已完成操作，不显示聊天正文。回复长度和工具数量事先未知，使用不定总量进度，不以定时器伪造进展。

## 长任务边界

按用户要求去掉原有 120 秒整轮计时和 12 次模型请求上限。`SessionMetadata.deadline` 保留旧数据解码兼容，新轮次写入 nil；旧 deadline 也不再终止正常推进中的聊天。单次模型调用的连接、首字节、空闲和总请求超时仍由 `ProviderTransportPolicy` 管理。限流退避、有限 HTTP 重试、权限、资料失效、记忆写入失败和用户取消仍生效。

Apple 不提供保证运行到任务完成的后台时长申请。系统资源不足、用户取消系统活动或强制退出应用均可能终止后台工作。此次实现不会自动重发中断请求，以免重复执行系统操作。真机实际获准时长需要在安装后单独验证。

参考：[Apple 长任务文档](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)、[Foundation 不定总量进度](https://developer.apple.com/documentation/foundation/progress/isindeterminate)、[Claude Code 默认不限制 agentic turns](https://code.claude.com/docs/en/cli-reference)、[Codex 长任务实验](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex)。这些执行循环用于设计参考，不能证明 iPhone 能取得同等运行时间。

## 验证范围

测试使用真实 PiDurableKit 执行和持久化路径、受控模型响应，覆盖授权开始时机、取消屏障、并行会话、页面切换、系统到期、重试与重新生成、重复回调、真实进展和超过 12 次模型请求的多步任务。FauxProvider 不能证明外部服务速度或 iOS 的调度接受率。

`tmp_agent_output/20261019-chat-background/portable/` 的小型 Swift 包直接链接生产源码与现有测试，排除无关语音模型依赖，使用独立构建缓存。原生后台适配器另以 iPhoneOS 27 SDK、iOS 18 部署目标和 Swift 6 检查 API 可用性与并发隔离；该检查使用最小消息类型替身，不等同于完整 App 构建。

最终回归：XCTest 54 项、Swift Testing 5 项全部通过，其中包含单轮 13 次工具调用后输出最终回答。SDK 类型检查、Info.plist 校验和 `git diff --check` 通过。首轮构建曾因本机磁盘不足中断；仅清理本轮创建的缓存后，使用较小的独立测试构建完成验证。

开发与测试在独立工作区完成，随后按用户指令合并至 main。本次未更新设备或启动模拟器。
