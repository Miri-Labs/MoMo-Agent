# 录音页面加载、预读取与缓存（2026-10-16）

## 本次范围

覆盖录音列表预览、录音详情、时间线列表与详情、引用打开录音、播放器预览。保留上一轮来源、文件编辑、路径与播放完整性校验；没有引入新的数据库迁移或服务依赖。

## 读取链路

- 列表使用 SQLite 的短文本查询获取首段最多 160 字预览，不再为了每行预览解码整份转录。
- ArchiveStore 按 session、version、generation 复用已解码转录；每次读取仍查询当前版本、删除与冲突状态。跨 SQLite 连接更新通过 `data_version` 清空缓存；事务内不复用或写入缓存，避免回滚污染。最多 8 项、合计 8 MiB 编码大小。
- LibraryModel 保留最近 3 份正文及时间映射，每份估算上限 4 MiB；刷新后仅低优先级预读最近两条，逐条进行。相同版本的并发预读和导航共享请求，录音版本、generation、chunk 数、音频状态或文件冲突变化后不复用旧快照。
- 录音详情先用有效缓存显示正文，再校验新快照，最后补同步/转写覆盖信息。补充进度读取失败不再抹掉已加载正文。缓存显示与同版本校验共用当前布局标记，避免打断返回页面后的阅读位置恢复。
- 时间线列表和详情共享正在进行的当天查询；详情直接匹配与分组变化后的回退匹配使用同一次结果，不再重复重建整天。已加载当天内容可先显示，后台仍重新读取；变更、删除与旧请求的接收边界继续生效。
- 全库文件对账、投影和问题检查在每条录音之间让出 actor；下一条重新读取当前状态，避免长任务连续占满读取队列。消除无变化时的投影状态写入。运行时合并重叠刷新，每轮只发布一次资料快照。

## 播放器

- 播放器先显示时长和控件，RMS 波形在 utility 优先级后台补齐。
- 波形增加版本化磁盘缓存，位置为 App 的 `Library/Caches/MoMoAgent/waveforms-v1`。key 包含资料库、录音、generation、manifest hash 和精确帧范围；排序编码生成稳定文件名。内存最多 64 片，磁盘最多 256 片，每片 256 个 RMS bin。
- 缓存损坏或被系统清理时从原音重建。iOS 文件使用首次解锁后保护；不缓存原始音频副本。命中波形缓存仍先获取并验证原音租约，不绕过 SHA、缺失、删除、来源和 generation 校验。
- 一个时间线播放请求中，同一 session 的完整元数据只构建一次，再裁切各段来源。

## 验证

- 最小 SwiftPM harness 直接引用正式 MoMoContracts/MoMoArchive 及全部归档测试：**134 tests / 23 suites 通过**。新增回归覆盖 4,000 段转录的重复读取、短预览不解码、修订/删除失效、外部 SQLite 更新和事务回滚。
- 合成 4,000 段样本连续读取 12 次正文及时间映射，约 **0.105 秒**，只发生一次正文解码。这是 Mac 上的回归样本数据，不是真机页面端到端测量。
- iOS 27 专用 iPhone 17 Pro 模拟器：**39 项集成测试通过**（LibraryPaginationIntegrationTests 11、TimelineReadingIntegrationTests 3、AudioPlaybackIntegrationTests 25）。覆盖真实 SwiftUI 导航返回与长短段落阅读位置恢复、转写追加、分页与搜索、预读取失效、原生播放/取消/seek、缓存跨 controller 复用、损坏缓存重建、原音损坏拒绝。
- 初次集成测试暴露缓存校验替换布局标记、打断导航返回后的恢复；修正后上述 39 项完整重跑通过。未运行字号矩阵，按当前项目要求使用默认字号。
- 合入最新 main 的并行对话、Avatar 与输入框改动后构建和验证；Release iPhone 包及其内嵌 Watch App 均为 **1.0 (4)**，签名构建与 `codesign --verify --deep --strict` 通过。

## 交付与实际限制

- 验证日志和 SwiftPM harness 在任务 worktree 的 `tmp_agent_output/`；iPhone 测试结果为 `DerivedDataRecordingCache20261016/Logs/Test/Test-MoMoAgent-2026.10.16_19-03-59-+0800.xcresult`。
- 签名完整包为 `DerivedDataRecordingCacheRelease20261016/Build/Products/Release-iphoneos/MoMoAgent.app`，包含 build 4 Watch App。
- 最终查询时 iPhone 和 Apple Watch 都为 unavailable。本次没有声称安装 build 4 成功，也未测量两台真机的最终打开速度；按用户要求，设备离线不阻塞 main 合并与远端推送。
