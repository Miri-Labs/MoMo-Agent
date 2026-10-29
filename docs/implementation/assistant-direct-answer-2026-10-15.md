# 私人助理直接回答与计划退役

用户要求直接谈事情，避免回复被“查了哪些录音”的过程说明占据，并取消产品计划功能。范围决定与旧库保留方式见 [ADR](../adr/personal-assistant-without-plans.md)。

## 改动

- AgentInstructions 统一承载系统提示。先回答用户的问题，闲聊不强制检索，已有上下文足够时不额外调用工具；取消强制逐字短引、固定报告结构与旧失败案例。具体事实用紧凑数字链接引用，需要核对原话或有关键冲突时再说明。
- 删除 write_plan 注册、实现和请求恢复中的计划检查，保留五个查阅／回听工具及来源、版本、请求时钟与删除边界。真实 Pi 测试尝试调用退役工具，验证被拒绝且没有新增文件。
- 删除手机计划页面、编辑器、导航、缓存加载与相关提示，移除旧工具标签。旧文件、SQLite 格式及来源清理兼容代码保留，当前 App 与 Agent 不创建计划。
- 前端仍只渲染真实消息和工具状态，不过滤模型措辞、不执行 Agent 工具。小屏最大辅助字号的输入区限制可见行数，编辑时欢迎语让出空间，全文仍保留并可滚动编辑。
- 真实 API/UI 场景改为问答、来源回听和重启恢复，故障服务器的分片用例改为只读搜索。J20 退役，旧 JSON 计划语料标为历史；不拿旧计划指标验收本版。LifeContextReplay 改为回答与原音校验，同时修正其 SDK 依赖，让它与生产代码使用同一份固定 Vendor。

## 验证

原始日志位于本机 `tmp_agent_output/assistant-simplify-20261015/`，保留首次失败与后续结果，不能合称一次全量回归。

| 验证 | 结果与范围 |
| --- | --- |
| Agent Swift 回归 | 36 通过，1 百炼付费测试跳过；真实 Pi／Archive，模型响应受控 |
| iPhone build03／build04 | 测试构建成功，含嵌入 Watch；未重新验证 Watch 采集 |
| iPhone tests03 | 16 项宿主集成通过；UI 3 通过、1 大字号发送按钮不可达 |
| iPhone tests04 | 修正大字号布局后，4/4 导航通过，包含最大辅助字号／软件键盘、计划入口消失与设置导航 |
| 离线渲染 JS | 9 项断言通过 |
| Python runner／故障服务 | Live UI 16、Live Agent 16、HTTP runner 5、HTTPS fixture 19 项通过；均为本地自检，没有收费请求 |
| CLI 工具 | LifeContextReplay 与 AgentCrashRecoveryReplay 构建成功，未执行远程模型调用或强杀场景 |

tests01 因磁盘不足与启动停滞主动中断。tests02 保留磁盘写入失败、旧文案断言失败、大字号和渲染失败；结果 bundle 未完整保存。修正旧断言并腾出空间后，tests03 的渲染、草稿、分页、凭据与旧库兼容均通过，大字号布局问题单独修复。

用户授权使用 Mole 清理后，删除 Swift 下载缓存、已安装的 Pen 安装包，以及不活动的 DerivedDataRelease27、DerivedDataRelease27-02、DerivedDataDevice、DerivedDataWatch。当前 DerivedData、最新 DerivedDataRelease27-03、模型、源代码和独立保存的验证记录保留；没有卸载应用、移除 runtime 或更改系统权限。

本地回归验证提示传递、工具边界、状态与界面，不证明真实模型语气已经满意。本轮没有新收费 API 验收；真实回答的语气与事实支持仍需单独复核。
