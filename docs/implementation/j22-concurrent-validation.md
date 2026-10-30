# J22 受控组合并发验证

状态：2026-10-14 Debug04 在专用 iOS 27 模拟器执行 1/1 通过，耗时 34.320 秒；已导出并独立核对三份 xcresult JSON 附件。本次受控组合通过，不能据此关闭 J22 的物理网络、设备与 Release 资源观测范围。服务自检 19/19 通过（此前服务为 17 项；新增两项覆盖受控断流鉴权、run 隔离与硬期限），runner 自检 5/5 通过。

`Tests/iPhoneIntegrationTests/ConcurrentWorkloadIntegrationTests.swift` 包含一个 XCTest，在同一 Archive、同一个 SpeechEngine 和 TranscriptionCoordinator 上顺序执行两轮：服务端强制断流、用户取消。每轮真实工作如下。

| 工作 | 输入和路径 | 必须检查的事实 |
| --- | --- | --- |
| ASR | 固定公开 `zh.wav` 哈希；重复到 60 秒负载，正式 VAD / SenseVoice / ONNX Runtime | 原生开始与返回时间、真实文本提交、native 同时在途最多 1、默认 20 秒 core 上限；重复输入不是中文质量基准 |
| Agent | 正式 ProviderAccess → Pi → AssistantModel → URLSession，真实 loopback TLS 与 SSE | 先观察服务的 `controlled_stream_started`；每轮最多 1 次 HTTP admission，无真实密钥或付费模型 |
| 收件 | 六个真实 1 秒 PCM WAV 分片；Inbox 保全 → commitReceivedChunk → SQLite outbox | 故障前、请求故障后、确认 Agent 收尾后各 2 片；取消可能立即收尾，不强称中间两片仍与网络并发；每次 accepted 的 Receipt 必须可从 pendingReceipts 读回 |
| 搜索与回放 | 另一个 60 秒公开语音重复音频；仅该资料的查询文字显式植入 | 正式搜索可命中；原生 AVAudioPlayer 已播放且没有错误；删除资料后搜索不可见，原音仍由播放 lease 保留，stop 后消失 |
| 最终释放 | 等待真实 ASR 结束，再删除其输入资料 | 原音立即移除，无残留 ASR lease；Agent 不 busy、取消状态持久化、无计划落库 |

并发屏障是 `nativeDecodeStarted` 回调发出的 XCTest expectation。回调只记录事件并立即返回，不用 semaphore 阻止真实 C 解码，也不以睡眠制造重叠。收件、搜索、删除完成点和故障请求点必须落在该轮真实 native 在途期间，且故障前 SSE 与回放仍在运行；没有观察到这个重叠直接失败。所有 native 起止、操作完成、故障请求与收尾写入 `j22-actual-overlap-and-latencies` xcresult 附件。由时间线判断实际发生的范围，不能把同时创建 Task 当成重叠证据。

独立回放资料和待转写资料使用过去时间，回放资料位于自动两小时上下文之外，ASR 输入更早以确保其最先调度。删除这一份资料检查共享存储与文件租约竞争；不把此处上下文缺席当成 J09/J25 的正向证据，资料修订与 Agent 来源失效继续由相应用例验收。

服务配置为 `Tools/AgentHTTPFaultServer/concurrent-timing.json`。每轮 body idle 5 秒、total 90 秒、最多 1 次 HTTP 尝试；服务 120 秒硬上限，超时没有 `[DONE]`，宿主必须失败。XCTest 最多 240 秒，runner 外层仍有限期和进程组清理。收件、搜索、删除记录实际延迟并用 5 秒作严重阻塞回归阈值，这不是 Release 性能预算。

开始前使用新编译的 xctestrun，在专用 HTTPS 模拟器导入本次临时 CA。测试结束由 runner 停止 Host 后移除本次受控工作目录；编排者另行停止并 wait 服务、清理专用模拟器 CA 和本次 TLS 私钥。不得修改主机信任或全局代理。新增 Swift 文件需要统一 `xcodegen generate` 后重建；不能直接用此前测试产物验证新源码。

这份证据只覆盖真实网络栈上的受控 socket 中断和应用取消。它不等同物理外网断开、公共 API、WatchConnectivity 持续收件、麦克风实时采集回调、真机后台、Release 锁等待/文件描述符/内存高水位。执行者数量、core 帧数、有限输入和 HTTP 次数可从本用例直接核对；数据库事务持有时长与全链路内存峰值仍需另行观测，不由功能通过推定。

## 2026-10-14 执行证据

证据目录为 `tmp_agent_output/resume-20261014-syh/j22-hosted-20261014-175146`，包含 `execution-report.json`、`inspection.json`、`j22-app-01/tests.xcresult`、导出的 `attachments/` 和服务事件。原生 callback 的起止区间独立重算后，两轮收件、搜索、删除和故障请求点均确实落在原生解码区间；没有使用阻塞 native 的测试 gate。

| 观测 | 服务端断流 | 用户取消 |
| --- | --- | --- |
| 实际 native decode 次数 | 11 | 11 |
| 持久收件确认 | 6 | 6 |
| 最大单次收件延迟 | 66.63 ms | 77.75 ms |
| 搜索延迟 | 2.49 ms | 1.04 ms |
| 删除资料延迟 | 6.25 ms | 3.71 ms |
| 请求故障后观察到 Agent 收尾的时间上界 | 368.86 ms | 91.96 ms |
| 模型 HTTP 请求数 / 正文字节数 | 1 / 35,674 | 1 / 1,198 |

两轮共 36 项 Speech diagnostics 全部 completed，其中 22 次原生解码，总 native 时间 4.181 秒、最大 core 70,240 帧；同时 native 在途最多 1，最终 0。首次模型准备较慢（从播放开始至第一次 native 事件约 20.67 秒），随后真实重叠仍成立。回放 lease、ASR lease 的物理文件删除断言均通过；SSE 两轮都没有正常完成标志或 fixture 期限耗尽，分别观察到 forced_disconnect 与 connection_closed/request_finished。

结束时 Host 已停止、唯一工作区已移除、服务进程退出且端口关闭；仅专用 HTTPS 模拟器 Keychain 重置以移除临时 CA，设备已关闭，本轮 TLS 目录及私钥已删除。主机信任与主 iPhone 模拟器未改动，公开 API 请求数为 0。
