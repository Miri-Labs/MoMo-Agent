# 系统行动与只读健康上下文实施记录

更新：2026-10-16。任务分支 `codex/personal-agent-system-actions`，在独立 worktree 实施，并合入实施期间的本地 main。远端 GitHub 的 TLS 连接失败；最终同步结果另见本文的交付状态。

本轮对应 [方案](../plan/personal-agent-system-actions.md) 的 A0–A3 软件实现，以及用户追加的只读健康上下文。A4 持续事项、A5 主动跟进仍属后续迭代。**真机发布门槛尚未验收，不能据此宣布方案首版完成。**

## 实现

- 直接删除 Agent 播放工具的注册、参数、播放回调、展示标签和播放专用提示词。按用户本轮补充，不保留专门的播放拒绝逻辑或拒绝测试。手动播放器、来源回放与音频租约保持独立。
- 统一 ASR 说明注入实际 Pi 系统规则、近期上下文、选定来源及每页搜索／读稿结果。允许有依据的语境理解；原文、引文、来源身份保持不变，行动所需关键歧义必须补查或澄清。旧上下文缺少新增字段仍可解码。
- 在原有 Pi Harness 中注入系统工具和健康工具，没有新增 Agent 循环、云端服务或独立计划功能。
- `SystemActionCoordinator` 管理连接、默认目标、运行时 actionID、同一逻辑请求去重、来源／取消检查、revision 冲突、局部 patch 和回执。独立 SQLite 账本采用 schema v1、WAL 与 FULL 同步，不修改 Archive 或 Pi 内部表。
- 写入前落盘；进入原生提交后无法确认结果时保存 `outcome_unknown`。恢复只读核对，不自动重放写入。EventKit 创建使用专属 action URL 标记；闹钟使用稳定 UUID 和提交前保存的配置。不能凭相同标题认定同一对象。
- 查询最多 500 个候选，单页 1–50 项，并按输出字节预算提前分页；游标绑定过滤条件和快照。列表不保存／返回完整备注。更新前重新获取原生对象，只应用改变字段；未指定字段保留，显式 null 清空可选字段。
- EventKit 使用长存活 `EKEventStore`。异步提醒事项查询在回调内转成 Sendable 快照，原生对象不跨隔离域传递。重复日程／待办可读，首轮不修改／删除重复系列。
- AlarmKit 限 iOS 26+，支持固定时间、每周指定星期与设备时区，不使用本地通知替代。系统不提供原子改期，保存旧／新配置后取消再调度；失败区分旧闹钟已恢复、旧闹钟已取消但新闹钟未设成及结果未知。iOS 18–25 保留其余能力，不注册闹钟工具。
- 设置新增「系统与健康」：各能力分别连接、默认可写日历／待办列表、健康开关及行动历史。聊天写入结果有独立卡片，可查看最新系统状态、编辑和适用的撤销。撤销为新行动，检查当前版本；已成功撤销的旧行动不重复显示撤销入口。
- 按用户最新反馈采用渐进披露：主页面只保留状态、操作和一行 AI 用途提示；分区标题旁用小圆圈 `info.circle` 打开说明。启用健康上下文时先展示读取范围及发往所选 AI 服务的内容，再进入 HealthKit 权限选择；取消不启用。
- 前台恢复及系统变化时核对未决行动；详情返回前台重新读取。已写入的系统事项属于用户资产，删除录音或断开连接不自动删除它们。

## 实际工具

| 能力 | 工具 |
| --- | --- |
| 录音 | `get_context_status`、`list_recordings`、`search_transcripts`、`read_transcript` |
| 记忆 | 既有 `memory`，仍只处理 USER.md／MEMORY.md |
| 能力 | `get_system_capabilities` |
| 日历 | `list_calendars`、`search_calendar_events`、`read_calendar_event`、`create_calendar_event`、`update_calendar_event`、`delete_calendar_event` |
| 提醒事项 | `list_reminder_lists`、`search_reminders`、`read_reminder`、`create_reminder`、`update_reminder`、`complete_reminder`、`delete_reminder` |
| 闹钟（iOS 26+） | `list_alarms`、`schedule_alarm`、`reschedule_alarm`、`cancel_alarm` |
| 健康 | `get_health_summary` |

写入工具不允许 SDK 自动重放；同一逻辑请求的重复调用由行动账本处理。单纯系统写入成功不代表 iCloud、Clock、其他设备或 Watch 已同步。

## 健康上下文

通过 **iPhone HealthKit** 读取已同步的数据，也包含可用的 Watch 来源；不是直接从 Watch 拉取实时传感器数据。

- 默认关闭，由设置页明确开启。HealthKit 只请求睡眠、步数、活动能量、训练的读取权限，`toShare` 为空。
- 每次新逻辑请求提供近 7 个当地自然日的简要初始上下文；同一请求重试复用摘要。另提供按需查询工具，范围最多 31 天。
- 日摘要包含可读的步数、活动能量、睡眠时长和训练次数／时长。重叠睡眠区间取并集，跨午夜按每日覆盖区间分配；训练按开始日归组。今天可能不完整。
- HealthKit 不允许推断用户是否授予某项读取权限；缺失值表示未知、未同步或不可读，不输出为零，不从中推断疾病或情绪。
- 本地偏好文件只存连接开关。摘要不写入 USER.md／MEMORY.md；启用后的初始摘要和工具结果会发给用户选定的 AI 服务，设置页明确说明。
- 关闭后停止后续读取和上下文使用。曾暴露健康摘要的会话保留本地历史，但后续模型请求只保留当前问题及其工具循环，避免旧健康工具结果或衍生回复再次发出。正在使用旧摘要的请求在下一次模型调用前取消。

工程来源 `project.yml` 已同步用途说明、HealthKit entitlement，以及 EventKit／HealthKit 和弱链接 AlarmKit。生成工程同步登记了原生文件；最低系统版本保持 iOS 18／watchOS 11。Watch 不链接这些手机专用能力。

## 验证与证据

本轮原始证据目录：`tmp_agent_output/system-actions-20261016/`，不入 Git。只使用本轮独立的 SourcePackages／Mac scratch 缓存、公开固定模型和一台临时 iPhone 17 Pro 模拟器（iOS 27.0 / 24A434）。没有读取真实健康记录、运行付费模型或修改用户真机日历。

| 证据 | 结果与边界 |
| --- | --- |
| `package-agent-tests-03.log` | 原始主包 MoMoAgentTests：89 通过、1 百炼付费测试跳过。真实 Pi + 脚本 provider、真实 SQLite；不是外部模型语义验收。早期离线 harness 结果单独保留，不累加 |
| `renderer-tests-05.log` | 14 通过。结果未知／权限／冲突按 receipt 展示，不把工具传输成功当写入成功 |
| `ios-build-09.log` | 最终 `TEST BUILD SUCCEEDED`，含手机测试宿主、嵌入 Watch 和小圆圈信息入口版设置页 |
| `life-replay-build-01.log` | 正式 `Tools/LifeContextReplay` Debug 构建成功，使用原始固定依赖与 `-enable-testing`；未运行付费入口 |
| `agent-crash-replay-build-01.log` | 正式 `AgentCrashRecoveryReplay` 构建成功；本轮未重新执行历史强杀场景 |
| `ios-tests-01.xcresult` | 29 通过、1 崩溃：设置默认关闭、3 项已有上下文集成、24 项手动播放器回归、原生日历 CRUD／冲突通过；提醒事项查询回调触发 trap，保留失败证据，修后结果单列 |
| `ios-tests-02.xcresult` | 2/2 通过。显式点击后申请 AlarmKit 权限、连接／断开，以及系统与健康默认关闭；早于渐进披露版界面 |
| `ios-tests-03.xcresult` | 5/5 通过、无跳过。修后原生日历 CRUD／冲突、提醒事项仅日期／改为具体时间／完成／外部变更／删除、AlarmKit 单次／每周／改期／取消及稳定 ID；另含真实 WebKit 的结果卡片、状态更新、周几与时间显示、原生打开回调和已有 Markdown／来源桥回归 |
| `ios-tests-05.xcresult` | 最终设置页 UI 1/1 通过。小圆圈入口打开系统说明，健康启用前披露范围和 AI 用途，取消后保持关闭，进入页面不请求系统权限 |

确定性测试覆盖：同请求重复写入／新请求独立写入、系统写入后失败与重开恢复、真实 SQLite 回执更新失败、局部清空与自动保留时长、外部编辑、取消／断开、撤销冲突、输出分页与游标失效、真实 Pi 工具调用及健康初始上下文／工具／关闭后的模型历史过滤。

原生测试仅在临时模拟器创建 UUID 标记的测试日历、列表、闹钟，并按创建身份清理。字号遵循 AGENTS 的系统默认字号约定。

本轮临时设备 `5B108A22-7549-47E9-BA6D-25C4FFCF2B00` 已关闭并删除，包含早期崩溃留下的测试资料。原始证据保留在任务 worktree `/Users/syh/Workspace/MoMoAgent-worktrees/personal-agent-system-actions/tmp_agent_output/system-actions-20261016`。

随 Git 保存的 [证据索引](evidence/2026-10-16-system-actions/evidence-index.json) 记录日志及结果摘要哈希；不把不同轮次测试数量相加。界面证据：[最终设置页](evidence/2026-10-16-system-actions/system-health-settings.png)、[健康启用前说明](evidence/2026-10-16-system-actions/health-enable.png)、[聊天行动卡片](evidence/2026-10-16-system-actions/system-action-card.png)。

## 尚未完成的验收

- iPhone 真机的系统 App 可见性、外部编辑与权限撤回、账号同步迟到；实际健康权限组合、Watch 同步数据与指标核对。
- AlarmKit 真机锁屏、静音／专注、App 退出／重启、时区变化、失败恢复及配对 Watch 呈现。模拟器调度检查不能替代这些验收。
- 当前真实模型对 ASR 歧义、后续纠正、来源中第三方命令、唯一目标选择和部分成功的语义判断；本轮没有自动消耗 API 额度。
- iOS 18–25 与 iOS 26 的实际版本矩阵；当前使用 Xcode 27 SDK 和 iOS 27 模拟器。

## 交付状态

代码和模拟器验证已完成，发布验收的未完成项见上节。实现提交保存在任务分支；本地 main 的合入与远端同步结果在最终回复中报告。GitHub TLS 故障期间不宣称远端已同步。
