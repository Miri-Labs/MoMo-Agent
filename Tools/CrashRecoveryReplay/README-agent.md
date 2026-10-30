# Agent 计划与历史清理的真实进程强杀

2026-10-15：J20 计划写入场景退役，runner 当前仅提供 J21/J23。其旧计划数据由 Archive 兼容夹具直接准备，不再通过 Agent 写入；下文 J20 结果仅属历史。

本工具覆盖 J20、J21、J23 的 Mac 软件持久化边界。使用生产 ArchiveStore、PiAgentHost、ArchiveTools、固定 Pi SQLite harness 和实际文件投影。仅模型响应由 FauxProvider 控制，合成文字通过正式 Archive 转写提交接口准备；不调用 API、ASR、模拟器或用户档案。

Python 复用本目录 `run.py` 的子进程启动、信号确认、日志保存与只读数据库函数。每例先由独立进程准备档案，再由实际业务调用到达观察点：子进程报告 PID 并 `SIGSTOP`，父进程通过 `waitpid(WUNTRACED)` 确认后发送 `SIGKILL`，退出必须为 `-9`。之后使用两个不同的新进程正常恢复、再重开。检查器不插入、修改或补写任何业务成功状态。

## 边界与恢复断言

| 用例 | 强杀时的实际边界 | 独立检查 |
| --- | --- | --- |
| J20-transaction | `savePlan` 已 INSERT，但 SQLite 事务尚未 COMMIT | 强杀后没有已提交计划或投影；同一持久 Pi 工具正常重放后只产生一份计划 |
| J20-committed | 计划事务已 COMMIT，投影尚未写入 | pending 操作存在而文件不存在；恢复保留同一计划 ID |
| J20-projection | 计划文件原子写入已返回，ready 登记尚未执行 | pending 操作与完整投影均存在；恢复正常登记 ready，身份不变 |
| J20-tool-result | Archive 已返回保存结果，Pi 尚未登记工具结果 | ready 计划存在，Pi 工具仍未完成；恢复返回同一计划，不重复保存 |
| J21-invalidated / J23-invalidated | 正式删除 / 修订事务及对应公开方法已返回，Pi 清理尚未开始 | 代次和 cleanup 队列已持久化，旧 Pi 历史仍在，旧请求不能恢复 |
| J21-closed / J23-closed | 已打开的 Pi harness 已关闭，旧目录尚未删除 | 旧目录与 pending cleanup 同时存在；重启完成清理 |
| J21-removed / J23-removed | 旧 Pi 目录已删除，cleanup 完成记录尚未提交 | 旧目录不存在但队列仍待处理；重启通过正式入口完成登记 |

J20 的恢复使用 `host.snapshot`、`host.retry` 与正式 `write_plan` 工具。检查原先中断的 `pi.tool` 持久 ID、调用输入不变且成为 terminal；原逻辑请求只生成一份计划。重复提交已完成请求不会再调用 provider。随后以相同文字发送一个新的 request ID，必须保存第二份独立计划。第二次重启后这两份计划的文档、文件 SHA-256、ID、操作键均不变，旧 request ID 不会重新入队。

J21/J23 在重启后的任何清理动作之前先尝试恢复旧请求，并重放旧来源的计划写入，两者都必须拒绝且 provider 调用数为零。清理由 `cleanupInvalidatedSessions()` 完成，投影由 `projectPendingDocuments()` 恢复。新会话交给实际 Pi→FauxProvider 的完整消息包必须不含旧标记；修订用例必须包含 v2 文本与版本。系统 section 与普通 `Message.text` 分开保存，检查完整编码消息以免遗漏 system 上下文。

独立 Python 检查采用 SQLite `mode=ro` 与 `PRAGMA query_only=ON`，执行完整性、外键、计划/清理/版本/索引和 Pi entries/tasks/submissions 检查；检查前后数据库与 WAL 哈希必须相同。文件投影内容与数据库、哈希对应。最终所有保留会话的应用请求为 finished、Pi task 为 terminal、submission 为 done，不能遗留 active owner。检查器的结果写在独立证据文件，不在业务数据库中。

拒绝断言使用精确错误类型：清理前旧会话须为 `AgentError.sessionInvalidated`；J21 旧写入须为匹配 session ID 的 `ArchiveError.sessionDeleted`，J23 须为 `ArchiveError.staleSource`。第二次新进程重开已完成清理的旧会话，必须是 `CocoaError.fileReadNoSuchFile`，同时旧会话整个目录确实不存在。SQLite、busy 或其他 IO 错误不会被算成成功的屏障拒绝。

## 运行

在仓库根目录执行，使用独占 scratch 和单编译任务。使用完整 Xcode 27，固定依赖不得漂移。

```sh
swift build --package-path Tools/CrashRecoveryReplay \
  --scratch-path tmp_agent_output/agent-crash-build/scratch \
  --force-resolved-versions -c debug --jobs 1 --product AgentCrashRecoveryReplay

swift build --package-path Tools/CrashRecoveryReplay \
  --scratch-path tmp_agent_output/agent-crash-build/scratch \
  -c debug --show-bin-path

uv run --no-project --offline python Tools/CrashRecoveryReplay/agent-run.py \
  --executable /absolute/build/output/AgentCrashRecoveryReplay \
  --output /absolute/tmp_agent_output/new-agent-crash-run
```

结果目录必须不存在。`--case J20-transaction` 可单独选例，也可重复使用。默认运行全部十例，任何失败返回非零并保留已产生的现场与日志。只有父进程创建的 worker 会收到信号。

观察 hook 仅在 `DEBUG && os(macOS)` 编译，默认 nil：`ArchivePlanBoundary`、`AgentPersistenceBoundary` 及各真实调用点。它们同步上报，不伪造业务状态。工具使用 Debug 的 `@testable import MoMoAgent` 注入脚本 provider，不新增生产 API 配置或网络入口。新增 package 源码不需要 xcodegen。

## 2026-10-14 证据

- `tmp_agent_output/20261014-agent-crash-build-01/build-03.log`：Xcode 27 / Swift 6.4，独立 scratch、jobs 1 构建通过。
- `tmp_agent_output/20261014-agent-crash-04/summary.json`：**10/10 通过**；全部真实 `SIGSTOP`→父 `SIGKILL`，各例四个不同 PID；包括同一 Pi 工具 ID 与最终任务终态断言。
- 经独立只读 review 收紧上述错误类型后，`build-04.log` 构建通过，`tmp_agent_output/20261014-agent-crash-05/summary.json` **10/10 再次通过**；每例 recover/verify 报告记录了具体屏障错误，05 是最新强杀证据。
- 每例保留 `fixture.json`、四阶段 stdout/stderr、`kill.json`、三份只读 snapshot、实际 provider 消息 JSONL、原始两类 SQLite、投影及 `result.json`。summary 保存可执行文件和相关源码 SHA-256。
- 同目录 `checker-negative-selftest.json`：两个真实只读快照基线被接受；在内存副本中故意改成 active 请求、running task、未结算 submission、未完成 cleanup、复活旧 Pi 目录、旧检索正文和 pending 计划，七种坏状态全部被拒绝。没有修改原始业务文件。
- 第一轮编译暴露工具代码把 `PlanDocument` 当成 Equatable，改成比较编码内容/身份。`agent-crash-01` 的 SQLite tuple/list 比较，以及 `agent-crash-02` 对 system.sections 的漏读，都属于检查器错误；原失败日志和现场保留。没有为了通过而修改业务状态或放宽产品断言。`agent-crash-03` 的十例已通过；04 增加持久工具 ID 与终态检查后再次通过。

## 范围限制

这不是模型质量或公网 API 验收，不证明收费模型只请求一次。它证明所列 Mac 进程被强杀后的软件恢复，不等同设备强退、熄屏、断电、文件系统损坏或硬件落盘保证。

清理观察点覆盖目录删除前后，不覆盖递归删除系统调用中每个文件的任意中断。J21 未模拟对端 Watch，删除待确认保持未确认；双端删除、迟到 WC/ASR、用户修改过或多来源计划等完整产品矩阵仍独立验收。J23 覆盖正式正文修订和旧 Pi 清理，不替代真实 Files App 移动、冲突或手工编辑全旅程。修订可保留 Archive 的历史版本；本轮要求旧版本不留在可恢复 Pi 历史、不出站，也不通过旧引用重新写计划。
