# 连接升级实现审查与验收

日期：2026-11-14。审查基线：`dc26d9e8`；原实现：`11d056de`。本记录覆盖用户要求的 agy 实测、实现 review、修复与复审。

## 结论

**代码检查通过，尚不能宣布真机断联问题已经解决。** Gemini 初审给出 2 个 P1、1 个 P2，修复后复审认为无新增阻塞。最终应用模拟器测试 48 项通过；公网 relay 互操作仍有 1 项跳过，45 分钟后台、切网、Mac 睡眠及 24 小时运行尚未实测。

- 模型：agy `gemini-4-carbon-high`，effort `high`。
- 会话：`e646f8b6-82b5-4392-a105-e12bb9058c28`。
- [实现初审原文](reviews/connection-implementation-gemini-initial-20261114.md)；[修复复审原文](reviews/connection-implementation-gemini-final-20261114.md)。
- 初始 headless 文件/命令权限拒绝导致的空响应、一次超时空响应不算完成 review。测试实际运行结束后，要求模型收束已有发现，得到完整初审；随后针对补丁重跑测试并取得复审。

## 发现、修复与证据

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| P1：自动恢复占用 `connecting`，扫码获批后 `connect` 可能静默空退；调用方把 `failure == nil` 当成功并清除待配对密钥 | 配对、恢复状态分开；显式配对抢占自动恢复；`connect` 返回是否实际生效；扫码与手动配置仅在返回 true 时清理 | 真实 PhoneRemoteAgent 模拟器用例：成功配对启动自动恢复后，显式配置仍能抢占并返回真实失败；忙碌配对明确返回 false |
| P1：独立笔记下载未在落盘前校验 workspace，旁路 status 的身份失败被忽略 | Mac 笔记页新增 workspace_id；手机逐页验证；缓存写入并校验 workspaceID；无身份的旧独立缓存等待联网验证 | 修复前新增用例在缓存、时间戳、错误提示三个断言上失败；修复后通过，新版/旧版响应与缓存兼容用例均通过 |
| P2：手动 reconnect 只等待原恢复任务，可能在排队的手动轮次完成前返回 | 在同一 scene 内循环等待当前恢复任务及补发轮次；场景改变即退出，明确手动意图不因 inactive 丢失 | 模拟器控制两轮探测响应，第二轮仍挂起时调用方不得返回，释放后两名等待方均结束 |
| 主审额外发现：退到后台取消 recovery 时会误清正在进行的配对互斥 | cancelRecovery 只复位恢复状态；配对状态由 connect 自己结束 | 挂起配对时离开前台仍保持互斥，不接纳第二次配对 |

新 Mac 的笔记内容自带身份，不必等待整理状态；旧 Mac 缺少身份字段时必须在同代次内通过 status 才可提交。旧版 status 不可用时保留旧缓存并显示失败，不能为了独立刷新而接纳未经身份验证的数据。已有 `context.json` 缓存兼容继续保留；原文及引用没有裁剪。

复审原文个别行号、路径属于审查时快照或误写。初审将工作树新加的 workspace_id 误认为旧 HEAD 已存在，已在复审纠正；Python 实际测试路径是 `Tests/AgentRuntime/test_momo_memory.py`。接受基于事件时序与源码核实的结论，不照搬“验证完备”等超出测试范围的表述。

## 实跑结果

| 检查 | 执行方 | 最终结果 |
| --- | --- | --- |
| 全部 MoMoAgentClientTests | agy 两轮亲自运行 | 157 通过、0 失败、1 跳过（共执行 158） |
| RemoteContextSyncTests 主机 harness | agy 复审亲自运行 | 22 通过、0 失败、0 跳过 |
| Tailnet 真实 Swift 生命周期 + SDK double + 本地 HTTP | agy 两轮亲自运行 | 7 组 PASS |
| Python memory，含真实本地 HTTP workspace 字段断言 | agy 两轮亲自运行 | 11 通过 |
| iPhone / 内嵌 Watch 完整应用构建与集成测试 | 主审，iPhone 17 Pro / iOS 27.0 / arm64 模拟器 | 48 通过、0 失败、0 跳过；[xcresult 摘要](reviews/connection-implementation-simulator-20261114.json) |
| 补丁格式检查 | 主审 | git diff --check 通过 |

48 项模拟器测试由 BackgroundGrantLifecycleTests 19 项、PhoneContextDeliveryTests 7 项、RemoteContextSyncTests 22 项组成。与主机 harness 有重叠，不相加冒充独立覆盖数量。仅使用默认字号和合成数据，配对测试使用独立 UUID 密钥并在结束时删除对应测试项。

唯一跳过项是 `RelayTests.testNativeClientAgainstUpstreamRelayAndPythonResponder`，需要另外启动上游 relay 与 Python fixture；没有把它算作通过。真实 Tailscale/公网线路未实测。

验证期间纠正了两类构建环境问题：源码变更期间产生的旧签名对象链接错误，清理本轮 App target 中间产物后重建；初始未完整签名的模拟器包未通过包含钥匙串保存的配对用例，启用模拟器 ad-hoc 签名后专项和全套测试通过。未更改真实设备签名、权限或凭据。

最终扩展测试中的既有 `testProcessLaunchWithoutSceneRestoresInboxAndQueuesReceipt` 在删除临时 `MoMoColdReceive-*` 目录时仍有 SQLite 文件尚打开的 teardown 告警。对应断言通过；此告警不等于真实用户资料损坏，也不能据此宣称所有生命周期和资源释放都已验收。保留原始日志供后续测试清理维护。

## 怎样判定实际使用 OK

“已连接”只证明一次请求可达；最终判定必须同时确认 **自动恢复、内容正确、确实落盘、不会再次永久停刷**。

1. **确认运行的是修复版本。** 对测试 Mac/iPhone 回读版本与构建提交，核对配对 workspace 一致。新版 Mac 的 `/v1/memories` 必须返回匹配的 workspace_id；先排除旧进程仍在运行。
2. **复现原场景。** 手机后台锁屏 45 分钟与 2 小时；期间在测试工作区新增一条可识别笔记。分别加入 Wi-Fi→蜂窝→Wi-Fi、Mac 睡眠→唤醒；再回手机前台，全程不重新扫码、不杀进程、不手动刷新。
3. **检查结果，不只看状态。** Mac 已醒且网络确实可达后，聊天恢复；新笔记内容出现在手机，“上次同步”更新，缓存落盘；重启手机 App 后仍能离线读到它。保留原聊天操作 ID、资料回执与本地草稿，无重复执行或丢进度。
4. **检查独立性。** 在 500 条资料积压、单条 503/413、整理状态慢响应时重复上述检查；笔记仍能完成刷新，单条故障不能使整轮持续重放。新版 Mac 不等待 review 状态；旧版按上面的身份降级规则处理。
5. **再验证稳定性。** 按升级方案执行每场景至少 30 次、累计至少 100 次切网/前后台循环以及 24 小时运行，报告所有失败与 P95，不能删除超时样本。健康网络的目标是连接恢复 P95≤5秒、规定数据集的笔记恢复 P95≤10秒；这些是验收目标，本次未测得真机数值。

时延起点 T0 必须由独立对照证明“网络与 Mac 已可达”，不能用系统 path satisfied 冒充。终点分别使用 authenticated 诊断和笔记缓存成功落盘；同时记录恢复 attempt/scene、失败类别、节点重建次数与资源趋势。只有通过上述实机门槛，才能认定用户的 42 分钟停刷问题已实际修复。

## 交付与清理

所有修改保留在独立工作树和任务分支，尚未合并、推送或部署，未改变主会话工作树及正在使用的应用。原始 review JSON、测试日志、修复前失败证据保存在 `/private/tmp/momo-implementation-review-20261114`；小型 review 和最终结果摘要已入库。本轮 DerivedData、SPM scratch、原始 xcresult、临时模拟器和资源符号链接均已清理，源码与主仓库模型保留。清理后原始证据约 3 MB，磁盘可用约 15 GiB。
