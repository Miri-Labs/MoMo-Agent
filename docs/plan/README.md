# MoMo Agent 方案

2026-10-15 用户范围更新：取消产品计划功能，助理直接回答事情本身。旧文档中保存、编辑与展示计划的要求由[最新决定](../adr/personal-assistant-without-plans.md)取代；历史证据保留原范围。

本目录集中保存产品、技术、代码组织和验收方案。用户已授权开始实施，实际进度和验证证据见[实施记录](../implementation/status.md)。

| 文档 | 内容 |
| --- | --- |
| [分类记忆与自动整理](dream-memory.md) | Hermes 源码对照、个人经历与稳定偏好的区别、承诺状态、来源核对、后台处理及验证边界 |
| [Omi 跨模块设计研究](omi-design-review-20261017.md) | 固定源码版本核对同步恢复、记忆、中文检索、纠错、派生索引与主动执行；区分本轮实现和后续建议 |
| [全天录音、持续整理与积压恢复](continuous-recording-processing.md) | 2026-10-17：不依赖录制结束，明确分片/同步/识别边界、独立状态、进度口径与待实施项 |
| [Personal Agent 系统行动详细方案](personal-agent-system-actions.md) | 首版必含日历、Todo、闹钟；移除 Agent 播放、ASR 语境理解、执行账本、冲突恢复与验收；仅方案，待专人实施 |
| [产品与技术方案](v0.1-plan.md) | 产品目标、采集与转写架构、录音候选方案及取舍 |
| [详细开发与验收计划](v0.1-execution-plan.md) | P01～P13、原型参数、接口契约、恢复规则与完成条件 |
| [代码组织方案](code-organization.md) | 六个业务模块、依赖方向、状态归属与扩展方式 |
| [分层验证计划](device-validation.md) | 固定输入、模拟器、真机和长时运行的验证步骤 |
| [E2E 测试总方案](e2e-test-plan.md) | 测试分层、真实依赖、数据与判定、自动化、CI、质量和发布门槛 |
| [E2E 用户旅程](e2e-scenarios.md) | J01～J28：从实际录音到带来源计划，以及故障、删除、升级和长时验收 |
| [录音详情页产品设计](recording-detail-product-design.md) | 针对详情页反馈重新定义内容、回听、助理入口与文件管理的层级；待实施提案 |

界面采用用户确认的[首版参考图](../design/v0.1-reference.png)：Watch 录音页、iPhone 对话首页和侧边菜单，计划使用 SwiftUI 原生 Liquid Glass。界面布局、交互状态和系统兼容范围需在实施前补齐方案。

[调研资料](../research/)保留来源、观察与推断，[设计资料](../design/)保存界面参考。调研结论与实施范围冲突时，以本目录内最新确认的方案为准。
