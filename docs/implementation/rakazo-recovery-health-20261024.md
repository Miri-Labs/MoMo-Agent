# Rakazo 审阅落实与健康资料最小链路

2026-10-24，MoMoAgent Beta 1.33.0。基于 `8bd8b946`，仅在 `codex/hermes-app-20261021` 开发。实施依据是人工核验后的审阅结论；保留 SwiftUI、Mac Hermes、内嵌 Tailscale 和既有资料层。

## 交互与恢复

| 问题 | 实现 |
| --- | --- |
| 已显示的补充后来未送达 | 稳定消息 ID 对应可变 `delivery_state`，随 runs 刷新同步，不依赖重新读取旧消息游标。未应用的定向补充不进入新任务历史；“改为新消息”只恢复草稿，等待用户发送。 |
| 电脑等待原因不清楚 | 区分用户接管、另一任务占用；子任务也投影等待原因。待审批/澄清时，确认无在途电脑操作后释放租约、更新 epoch 并丢弃旧观察；恢复必须重新截图。取消后的等待不复活。 |
| 排队取消绕过持久化 | 排队和运行都使用 work 取消日志与稳定 operation ID。排队目标绑定原 admission/run，正确处理点击后开始运行的竞态；请求 ACK 不冒充原生终态。 |
| 已执行但结果汇报失败 | 保存原结果，界面显示“结果回报未完成”和“重新汇报”。独立 report attempt 只读保存结果，宿主拒绝其工具调用；重试不重跑原任务。 |
| 不知道其他任务进展 | 第一轮临时上下文提供最多 12 项运行、等待和回报失败事实，只读且不写长期记忆。 |
| 单条接纳失败阻断维护 | 永久拒绝标记为 rejected/not_applied；逐项隔离暂时故障，使取消与完成处理继续。 |

借鉴 Rakazo 的送达与消费区分、待输入释放电脑租约、完成结果补投。未引入其 Pi、云电脑、数据库或 Expo。已有消息边界标记保留，避免改变旧 operation 的原生幂等请求内容；Hermes 继续负责模型循环、会话、执行和长期记忆。

## 手机健康资料

链路：HealthKit → `PhoneHealthSync` → 已配对资料通道 → Mac `health_snapshots` → 本机 MCP `read_health` → Hermes。

- 手机“设置 → 健康”主动开启，默认关闭。授权说明包含同步到用户 Mac、相关问题使用所选 AI 服务。普通同步不会重复弹授权。
- 仅读取最近 7 个当地自然日的每日步数合计，以及该窗口内最新一条心率。步数标明 Apple Health 合计，心率携带实际样本来源；不上传完整逐条记录、睡眠或训练档案。
- 前台进入、手动刷新和前台每 5 分钟刷新。没有锁屏实时或后台常驻承诺。
- 设备 ID + 单调 revision + 完整待发送快照持久保存。ACK 丢失后先重投同一快照；同版本不同内容冲突，旧版本不覆盖新版本。
- 停用立即停止采集，持久投递更新版本的空快照。离线时显示待移除，可重试；旧上传无法复活已移除资料。读取失败用 unavailable 空快照撤下旧值，不把旧数据包装成新值。
- 工具返回覆盖区间、时区、单位、来源、观测/接收时间、快照与样本年龄；超过一小时标记 stale，设备时间领先也单独标记。多设备明确分页，不自行累加重叠数据。
- 无样本表示没有可读取数据，不代表零，也不能据此断言读取权限被拒。今天的步数可能不完整。
- 健康只按需读取，不生成记忆整理任务，也不自动注入具体数值到普通聊天 prompt。用户已收到的聊天回答不会随停用删除。

实现入口：`Apps/iPhoneApp/Features/RemoteAgent/PhoneHealthReader.swift`、`PhoneHealthSync.swift`、`Apps/MacApp/Context/health_store.py`、`context_mcp.py`。传输沿用既有配对鉴权与 Tailscale/自建入口，没有手机常驻服务。

Apple 依据：[读取授权的隐私语义](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)、[统计来源语义](https://developer.apple.com/documentation/healthkit/hkstatistics/sources)。日累计未按来源拆分，不能把合计伪称为某一设备的记录。

## 验收

- Swift 客户端 63 项通过；交互 12 项、健康存储/API/MCP 7 项、prompt 6 项通过。RTC 10 项通过，4 项需外部 native probe 的用例跳过。
- Hermes 官方 runner：19 项接纳/投影/完成投递及 25 项工具门控/检查点/审批回归通过。
- 真实内置 Hermes + 本地脚本模型：独立澄清/审批、定向补充、精确取消、电脑等待交接及报告恢复通过。根 agent 单独重跑报告恢复，确认原进程只执行一次、重试工具副作用被拒、两客户端取得同一回报。电脑实际设备层使用合成私有 IPC。
- 真实 HealthKit 读取器和同步器可编译；注入数据源的 Swift probe 验证授权失败、丢 ACK 后重启、读取失败撤回和离线停用。真实 Hermes 经生产 MCP 读入合成健康数据，4 个模型轮次完成，没有读取用户健康数据。
- 已编译 Mac UI 使用合成服务验证恢复草稿不发送、区分另一任务占用、重新汇报后保持草稿。两次重试 HTTP 请求复用同一 operation，产生一条回报。
- Mac Beta 和未签名手机 Beta 完整构建通过；手机、Watch、Widget 的 29 项包检查通过。构建存在已有 Xcode 文件组引用警告，不影响通过结论。
- 已替换 `/Applications/MoMoAgent Beta.app` 为 1.33.0，bundle 为 `com.momoagent.mac.beta`。实际输入框发送升级验收消息，真实配置模型回复“已就绪”，API 确认为 completed。正式版未改，手机按用户要求暂不安装。

证据目录：`/Users/syh/Documents/Codex/2026-10-21/jie-he/outputs/interaction-recovery-1.33.0/`。构建、协议与合成检查不代替真机：HealthKit 实际授权/样本、手机跨网与锁屏恢复、真实 APNs 投递、CuaDriver 系统权限和真实窗口输入仍待验收。
