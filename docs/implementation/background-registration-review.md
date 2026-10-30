# 后台转写注册问题与修复验证

2026-10-14，Xcode 27.0 / 27A266a。最初只读复核发现下述问题；后续修复已通过 Debug05 构建与 14 项受控测试。后台转写策略仍为 `foregroundOnly`。

修复前的真实 iPhone 模拟器宿主日志出现：

```text
[Framework] Registration rejected; com.momoagent.ios.transcription.continued.* is not advertised in the application's Info.plist
```

Debug 与新 Release 产物的 `BGTaskSchedulerPermittedIdentifiers` 都含 `com.momoagent.ios.transcription.processing` 和 `com.momoagent.ios.transcription.continued.*`。静态声明存在，但这不能证明系统接受了运行时注册。

当时 `PhoneBackgroundTasks.register()` 注册的是字面值 `continuedPrefix + "*"`；`requestBatch(id:)` 提交的却是 `continuedPrefix + UUID().uuidString`，没有为这个具体标识注册处理器。这是生产实现中的标识不一致，不是缺少 plist 条目。

Apple 在 [WWDC25「Finish tasks in the background」13:29–14:28](https://developer.apple.com/videos/play/wwdc2025/227/?time=809) 说明：Info.plist 使用通配模式，注册处理器和提交任务时都附加动态后缀，使用同一个完整标识。continued processing 的处理器可以在用户表达意图时动态注册。修复前实现与该契约不一致，也与实际注册拒绝日志相符。

本机 iPhoneOS27.0 SDK 的 `BackgroundTasks.framework/Headers/BGTaskScheduler.h` 注册方法注释与 `BGTaskRequest.h` continued request 初始化注释分别说明注册标识与 plist 的许可关系、通配模式和具体请求标识。Apple 演讲明确补足了“注册与提交都使用具体后缀”这一要求。

## 修复前的隔离范围

`PhoneBootstrap` 使用默认 `foregroundOnly`。启动仍会调用 `register()`，因此默认策略也会遇到注册失败并可能显示错误；`registrationSucceeded` 为 false。

自动安排与用户批次的后台提交都要求 `validatedCPU`，且提交前检查注册结果。当前前台 ASR 仍可工作，但若只将策略切成 `validatedCPU`，后台安排也会被拒绝。受控 grant 测试、plist 检查以及 Release verifier 通过均不能证明真实后台调度可用。

修复需要为每次 continued request 的具体标识注册一次处理器，再用相同标识提交，验证注册返回值、取消、系统到期、批次身份和重启行为。自动 processing 的固定标识仍须独立验证。修复后仍维持 `foregroundOnly`，直到真实 iPhone 的取消、能耗与后台预算验收通过。

## 保存的修复

`PhoneBackgroundTasks.register()` 在应用启动时仅注册固定的 processing 标识。`requestBatch` 保留策略、系统版本、前台状态与现有 grant 检查；通过后才为本次 UUID 创建具体 continued 标识，先注册成功再提交相同标识，不再注册字面通配符。系统 callback 也检查它与注册标识一致。

新增 `ContinuedBackgroundSubmission` 只持有 scheduler 请求身份与 pending/active 准入状态，便于用受控的异步 callback 验证生产竞态。ASR、归档持久状态和停止屏障仍由原有 coordinator/grant 负责，没有增加旁路执行入口。

- 注册拒绝时不提交。提交失败只取消对应标识，释放尚未派送的 pending 请求。
- pending 被用户取消后，旧 callback 不再认领批次；异步提交稍后成功或失败时只再次取消旧标识，不触碰后续新请求。
- 相同 callback 只能认领一次批次；错误或过期标识被拒绝。认领后保留 active 身份，直到 `TranscriptionTaskGrant` 完成才释放。
- 若 iOS 27 的提交错误晚于任务派送，取消该标识并令对应 grant 按 `.interrupted` 停止。正常取消与系统到期继续沿 grant 的持久停止屏障结束，不能提前放行另一个用户批次。
- 系统可能先完成工作、后返回提交结果。这个迟到结果只取消自己的旧标识，不能清空新批次。

本机 SDK 要求同一标识只能注册一次；公开 `BGTaskScheduler` 没有注销 handler 的接口。因此每个请求使用新的 UUID，旧注册 handler 只保留弱 runtime 引用和具体标识，不捕获录音、coordinator 或批次快照。进程内不重用标识；进程重启不恢复内存里的 continued 准入、不自动重新提交旧用户意图。正式转写账本的中断恢复仍走已有归档恢复流程。上述约束不等于已验证系统终止/重启的实际调度行为。

## 验证状态

新增 `ContinuedBackgroundSubmissionTests` 的 8 个受控用例覆盖上述身份与异步回复边界；没有构造私有 `BGTask`、调用私有模拟调度方法或更改后台策略。现有 `BackgroundGrantLifecycleTests` 覆盖准备/准入阶段的系统到期、持久停止屏障、早到完成与停止写入失败；`AutomaticBackgroundSubmissionTests` 覆盖固定 processing 标识的迟到取消。三者应一起执行，不能用受控测试替代实际 iPhone scheduler 验收。

Debug05 统一构建通过。`ios-background-27-01` 在新构建上执行 14 项定向用例全部通过：新增 continued 8 项、automatic 2 项、grant 4 项；该轮宿主启动日志没有再出现 `Registration rejected`。这证明已构建源码的受控生命周期回归通过，旧字面通配符注册错误在本轮启动中未复现；不证明系统已接受或执行真实 continued 请求，因为默认前台策略没有提交这类任务。

真实 iPhone 的处理器接收、系统到期、取消、进程终止、热状态与能耗仍保留为设备阶段门槛。

## 本轮证据

- `tmp_agent_output/20261014-xcode27-release-02/background-registration-review.json`：实际声明、调用链、官方来源和影响范围。
- `tmp_agent_output/20261014-xcode27-release-02/release-bundle.json`：19 项静态产物检查通过，范围不含后台注册或调度验收。
- `tmp_agent_output/20261014-xcode27-release-02/evidence.json`：对应源码、产物与工具链摘要。
- `tmp_agent_output/resume-20261014-syh/ios-background-27-01/summary.json`、`test.log` 与 `tests.xcresult`：本轮 14/14 受控测试和宿主启动日志。

这项问题属于尚未开启的后台策略修复与设备阶段验收，不改变本轮前台转写或 Release 静态打包结果的范围。
