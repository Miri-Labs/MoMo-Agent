# 受控写入失败与恢复

2026-10-14：按 J10/J12 审计补最小软件故障边界。测试只使用各自临时目录和小型 SQLite 页数上限，不耗尽宿主卷，不修改模型、模拟器权限或生产故障注入入口。原有容量预检、损坏输入、进程强杀和外部文件编辑测试仍是不同证据。

## 范围

| 用例 | 真实失败 | 必须保持与恢复的状态 |
| --- | --- | --- |
| `CaptureSealWriteFailureTests` | 真实 AAC 尾段关闭后，现有 checkpoint 只改变专属目录权限；正式 sealed sidecar 原子写返回 Cocoa 513 | 已入账未确认片和可解码尾段不丢；draft 帧范围不变；恢复权限后 `CaptureSpool.recover` 正常入账，重复恢复不增片 |
| `ArchiveWriteFailureTests.rejectedAudioMove…` | 完整 Inbox 保存后禁止来源目录 unlink/rename；正式文件搬移返回 Cocoa 513 | Inbox 原音 hash 不变，无目标原音、无成功 Receipt、无录音行；恢复权限、重开并 `processInbox` 接收，重传返回同一 Receipt |
| `ArchiveWriteFailureTests.sqlitePageLimit…` | 对专属 Archive 连接设置当前页数为增长上限，提交约 1 MiB 合法合成文字触发实际 SQLite 容量错误 | 正文版本、搜索索引、会话版本与 job 保持事务前状态；原音和既有接收确认不丢；解除上限后同 ticket 重试、重复提交拒绝，重开可读，完整性检查通过 |
| `ArchiveWriteFailureTests.deniedTranscriptProjection…` | 先正式生成录音 manifest，再禁止目录写入；正式 transcript 原子写返回 Cocoa 513 | 已提交 DB 正文保持，投影版本不前进且读稿被阻止；解除权限后重开，经 `reconcileDocumentFiles` 和 `projectPendingDocuments` 生成正确 JSON/Markdown，无新正文版本 |
| `RecordingLedgerWriteFailureTests` | 32 片共 10 KiB PCM 经正式封口入账后，限制专属连接页数，逐个正式 `applyReceipt` 至真实 `SQLITE_FULL` | 错误码保留 13，失败片仍 ready、无 ReceiptApplied，全部原音 hash 不变；解除限额后同 Receipt 重试和重复幂等，只清理已确认片，重开后其余待传片仍在 |

权限和 SQLite 上限均有收尾恢复。测试数据是可丢弃的合成音频/文本；没有真实用户录音或模型请求。AAC 用例证明的是**编码后封口发布失败**，不声称覆盖 native 编码中途的 ENOSPC。真实设备低空间、编码中的 I/O 失败、文件保护状态仍是独立未完成项。

## 首轮结果与实际缺陷

`tmp_agent_output/resume-20261014-syh/j10-write-failures-01`：四项定向测试，2 通过、2 失败；独立 scratch、jobs=1、编译运行约 145.8 秒，前后全部共享 Sources/Tests/Pi Sources 哈希未变。

- AAC 封口发布和 transcript 投影通过。
- Inbox 搬移的全部故障和恢复断言通过，但测试的 defer 再次给已被正常处理删除的 Inbox 目录恢复权限，导致清理断言失败。已把权限恢复器改成成功恢复后记录状态，最终轮通过；原失败保留。
- SQLite 故障的事务、原音、确认、同 ticket 重试、完整性及重开断言通过，错误分类失败：应保留 `SQLITE_FULL`（13），实际为 `ArchiveError.database(1)`。`ArchiveDatabase.transaction` 在 SQLite 已自动回滚后再次执行 `ROLLBACK`，覆盖了原始错误。

同目录 `sqlite-native-autocommit-probe.json` 独立调用 macOS `/usr/lib/libsqlite3.dylib`（3.51.0），对独立小型 WAL 数据库复现：写入返回 13，`sqlite3_get_autocommit` 为 1，再次回滚返回 1。探针数据库、WAL 和 SHM 已删除；另有 Python SQLite 3.50.4 对照，不能把其版本当成 App 使用的版本。

SQLite 官方明确说明 `SQLITE_FULL` 等错误可能自动回滚，再次 `ROLLBACK` 将报错；可用 [`sqlite3_get_autocommit`](https://www.sqlite.org/c3ref/get_autocommit.html) 判断状态。参见[事务错误处理](https://www.sqlite.org/lang_transaction.html#response_to_errors_within_a_transaction)。Archive 与 Recording 的事务 catch 均已采用最窄修补：仅当事务仍活跃时执行回滚，保留实际回滚失败；SQLite 已自动回滚时直接抛最初错误。没有更改事务内写入顺序或存储格式。

## 最终定向结果

`tmp_agent_output/resume-20261014-syh/j10-write-failures-02`：上述 **5/5 通过**；jobs=1，含清理缓存后的编译共 94.68 秒，测试运行约 0.36 秒。运行前后六共享模块 Sources/Tests 和 Pi Sources 哈希全部一致。权限、SQLite 限额和专属临时 fixture 收尾成功；没有模型推理、付费 API、全量测试或模拟器运行。Recording 的原始错误覆盖是对同类代码的静态发现，没有另跑旧实现的 ledger 负向基线；最终实际小配额用例确认修补后严格保留 13 及资料安全。

最终生产文件 SHA-256：

- `MoMoArchive/SQLite.swift`：`2ea1beb462f7a1fa26a43a63c4fc443e2b047265cd51329438a660fc4653ce03`
- `MoMoRecording/Ledger/RecordingDatabase.swift`：`e10c352f795de9bfeb431e8d4f5b5d05415d4703dd9f8a099205cbba560a2169`

本轮证明 Mac 上真实文件权限和 SQLite 页数限制的失败/恢复，不代替手机、Watch 的实际低磁盘、掉电、原生编码中途 I/O 或后台验收。最后平台构建和核心 smoke 由根任务在最终源码上另行执行。

## J12 其余边界

根任务的 Debug09 `ModelRecoveryIntegrationTests` 三例已通过：模型缺失/损坏和同实例直接重试由真实本地模型验证，不在这里重复。既有配置 fingerprint 和批次屏障验证不能替代处理中实际切换模型的端到端验收。仓库准备脚本有临时下载、固定 hash 校验及最终 manifest 发布，但 App 首版没有用户可切换模型下载管理界面；下载中断、tokens 不匹配、空间不足的安装重试仍需按实际适用范围独立说明。冷启动 3 次、热运行 5 次、1/2/4 线程及真机温度/后台比较也不能由本次五个写失败测试或 Mac J27 重复压力输入替代。按用户“第一版能用”的最新范围，本轮不继续扩展这些验证矩阵。
