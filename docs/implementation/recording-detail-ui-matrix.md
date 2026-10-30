# J26 录音详情 UI 覆盖与下一轮矩阵

2026-10-14，只读审计及待执行方案。本文件没有新增测试通过结论，也没有修改 Swift、工程或模拟器状态。

## 已有证据的范围

`tmp_agent_output/resume-20261014-syh/ios-offline-27-01/summary.json` 与 `xcodebuild.log` 确认 Debug06 普通测试 83/83，其中 UI 10 项。以下按实际测试源码划分，不能把 10 项统称为录音详情矩阵。

| 已通过用例 | 已证明的行为 | 未证明的相邻场景 |
| --- | --- | --- |
| `PhoneRecordingJourneyTests.testRealLocalTranscriptionSurvivesRelaunchAndDeletion` | 短公开音频真实 ASR、段落回听、更多菜单、保留说明、范围/标记、提问草稿、44 点引用移除、重启与删除 | 长正文、大字体详情、已过期/缺片、VoiceOver |
| `testNoSpeechRecordingPlaysReceivedOriginalAndSurvivesRelaunch` | 真实 VAD 无语音状态、整段原音回听/自动结束、重启与删除；不生成假来源 | 部分原音不可用的无语音记录 |
| `testWholeRecordingStopRemainsWhenTranscriptionArrivesDuringPlayback` | 先暂停转写，播放时真实正文到达，停止按钮仍可操作 | 多个段落持续更新、缺口补传、长稿滚动位置稳定 |
| `testMissingTranscriptRequiresPreviewBeforeRestoring` | 实际移除 `transcript.md`，阻断旧稿显示，预览后显式恢复，重启保留 | 两份文件冲突、预览取消、确认时再次变化、文件/播放错误后的重试 |
| `PhoneExportJourneyTests.testNativeTranscriptShareCanBeCancelledAndOpenedAgain` | 原生分享取消/再次打开 | 过期原音和缺片时导出选项的 UI |
| `PhonePlanJourneyTests` 两项 | 计划 CRUD、Markdown 阅读/源文保留；计划页 Accessibility XXXL 可滚到尾段 | **录音详情** 大字体与长正文；长中文输入/键盘遮挡 |
| `PhoneNavigationTests` 两项、`PhoneStorageJourneyTests` 一项 | 无凭据导航、拒绝 HTTP 配置、容量和未加载模型状态 | 详情异常、可访问性和外观 |

另有 `live-ui-27-03` 的真实 API 旅程，覆盖从计划打开 `SourceExcerptView` 原文 sheet、回听、关闭、重启后计划与聊天仍在；不等同于从聊天来源进入完整 `RecordingDetailView` 再返回原会话。Release04 的四页人工检查只是首页、设置、资料/计划空态、默认字号；没有录音详情。Release05 当前只有构建/静态检查。

共享 Archive 的时间映射、缺口、保留/过期、Files 修复和原生 Audio 10 项，是下面 fixture 的可信基础；它们不是对应 UI 已通过。现有全部 UI 测试未调用可访问性审计，也没有 VoiceOver、深色、减少动态效果或降低透明度的执行证据。

## 最小下一轮矩阵

建议新增一个 `PhoneRecordingStateTests` 文件，复用既有 UUID 隔离档案、普通 UI target 和公开 `zh.wav`，一次构建后只跑下列新增用例。先保留已通过 10 项，不为凑覆盖重复执行它们。

| 编号 / 建议用例 | 正式状态准备与可复用能力 | 必须断言 / 保存的证据 |
| --- | --- | --- |
| R01 `testLongTranscriptAtLargestTypeKeepsContentAndDraftReachable` | 同一有效录音的 80–120 个合法源帧段、固定首/中/尾标记和至少 10,000 中文字符，通过 `commitTranscript` 写入；明确是 UI 合成文字。沿用计划测试的 Accessibility XXXL 启动参数 | 首/中/尾标记均可滚动到；正文未截断/改写；段落回听与更多可点；底部提问不遮挡最后一段；进入草稿后输入至少 2,000 中文字符，键盘展开时引用移除与输入仍可达，不发送请求。保存顶部/中部/尾部/键盘截图和 AX 文本。长稿不等于长时间真实采集。 |
| R02 `testKnownGapAndPendingTextRemainDistinctFromCompleteSync` | 复用 `ArchiveCoverageTests.duplicateAndOverlappingAnalysisUseFrameUnionWithoutFillingMissingAudio`：接收第 1、3 片，正式 `receiveEpochEnd` 声明已知末尾，仅提交第一片文字，余片保持 pending；另一个记录不发结束消息 | 已有文字可读/可回听；状态说明尚有录音未到手机；范围里缺口位置精确；未收、未分析/转写、未知末尾不混成静音/已全部同步；缺口标记不能播放。截图应同时含正文和状态。 |
| R03 `testExpiredAndPartiallyExpiredAudioKeepTranscriptReadable` | 复用 `TranscriptLocationTests.locationsUseEpochClockAndKeepTextWhenAudioExpires`：两个真实音频片，应用业务 receipt、提交文字，用正式 `applyRetention(now:replayFloors:)` 分别到期一片/全部。不能靠删文件伪造到期 | 正文/时间不变；过期段无可用回听，尚存段可真实播放；提问引用仍能加入草稿；全过期时保留开关禁用并解释不能恢复；部分/全部过期文案区分。两种状态各保存截图。 |
| R04 `testUnexpectedMissingAudioCanBeRepairedWithoutLosingText` | 复用 `ArchiveStoreTests.matchingRetransmissionRepairsMissingStoredAudioBeforeAcknowledgement`：在本次隔离档案实际移除一个原音文件，正式扫描确认 `.missingUnexpected`；随后从保留的公开原始 fixture 经同 manifest 的 inbox/commit 重投 | 丢失文案不说“按设置清理”；文字保留；不可用段不误报播放；匹配补传后同录音/版本文字恢复可回听；另一片仍可用。记录缺失前/修复后音频 SHA，使用真实状态而非 View 直接注入。 |
| R05 `testConflictingFilesRequirePreviewAndExplicitChoice` | 在已有投影上分别修改 `transcript.json` 和 `transcript.md`，沿用 `RecordingFileRecoveryTests` 的实际冲突和正式 `reconcileDocumentFiles`/预览/恢复入口 | 冲突时旧正文与提问不可冒充当前资料；两种候选动作可达；先取消预览应保留冲突与两份文件；再明确选择一份，显示精确选中正文，另一份不得静默合并；重启保留选择。 |
| R06 `testPlaybackFailureIsVisibleAndRetryClearsItsError` | 复用原生播放器测试的真实坏文件方法：在 lease 校验后、原生播放器打开前，对本次公开 fixture 文件写入无效容器，之后匹配补传恢复。此场景需一个严格 Debug、默认 nil、一次性同步边界，现有冷启动 `DocumentChange` **不能**控制这个时序 | 真正播放失败后不出现“正在播放”；错误出现在发起操作附近；回退/恢复不会丢稿；恢复后的真实回听成功，旧错误消失、停止按钮有效、lease 可释放。仅播放器集成抛错通过不能替代这项 UI 结果。新增边界实现须先明确范围，不能伪造播放器成功/失败状态。 |

R01 的最长字号用例执行后，可复用同一隔离档案做深色外观与辅助设置人工检查；无需再次导入/转写或调用模型。R02–R05 先写状态构造自证：读取正式 summary/coverage/版本/文件 hash，确认预期状态后才启动 UI；状态不成立必须直接失败，不能让 UI 测试空通过。

### 可访问性和来源返回的独立人工步骤

1. 对 R01 的长稿及 R03 的过期稿，使用真正 VoiceOver 遍历：日期→状态→段落时间/正文/回听→更多→提问；确认朗读名称包含动作/停止状态，重复“回听”按钮能定位所属段落，转写更新不把焦点任意拉走。完成菜单、保留、删除确认及取消；记录系统 VoiceOver 是否真实启用、焦点顺序和失败项。AX 树存在或标签非空不能替代此步骤。
2. 同一稿件在浅/深色、减少动态效果、降低透明度下分别检查系统玻璃上的文字/图标和底部安全区；截图与设置状态成对保存。只在授权测试设备内更改并恢复这些设置，不改宿主全局设置。大字体截断、按钮重叠/触摸目标问题必须先修复再复验。
3. 已有真实聊天来源可用时，从**聊天**打开原文 sheet、关闭后检查当前会话、草稿和滚动位置；再检查过期原音、已修订来源的提示。当前实现是原文摘录 sheet，没有跳到完整录音详情的入口；这是路由事实，不把该不存在的流程写成已经验收。若要新增路由，另行确认范围。

## 夹具接线和证据边界

- `PhoneUITestConfiguration` 当前只支持 `1`、`silence`、`speech-playback` 三个导入模式及 `remove-markdown`。除可沿用的 UI 导航外，R01–R06 都需要窄范围 Debug fixture 扩展；**当前开关不能直接运行这个矩阵**。涉及 actor 的 Archive 预置应在隔离 runtime 正式开始前串行完成，不能绕过收到/提交/代次屏障直接写 SQLite 或注入 `RecordingSummary`。
- 用现有公开 WAV 和真实 manifest/hash，合成文字/故障只写入测试 run ID 的目录。长稿用于布局压力，不能记作长音频 ASR/18 小时采集。真实连续长录音的性能、热量和动态滚动更新仍须分别引用 J27/设备证据。
- 原音已删除、已到期、未收到是三种不同状态；过期依赖业务确认与 replay floor，缺失使用真实文件故障，缺口使用源帧范围与结束消息。测试不能改状态枚举以获得期望画面。
- R05 的“确认预览时文件又变化”尚未包括在最小集；现有共享恢复测试覆盖拒绝过期 issue，但该错误 UI/重新预览另需受控变化时序。不要宣称全部错误恢复完成。
- 无语音的“没有检测到说话声”已通过；“真实识别完成但返回空文字”及“用户删除全部正文”在共享层分别有契约，尚无各自 UI 用例。可在同次夹具扩展后追加，但不能将其标成无语音。
- 每项保留源版本、fixture 模式、App/build 哈希、原始 xcresult、失败截图与 AX 层级；成功还要人工读实际截图。发布包继续检查这些测试模式/故障边界与 fixture 均不进入 Release。

## 代码和证据入口

- [现有录音 UI 旅程](../../Tests/AppUITests/PhoneRecordingJourneyTests.swift)、[大字体计划旅程](../../Tests/AppUITests/PhonePlanJourneyTests.swift)、[真实来源旅程](../../Tests/AppUITests/PhoneLiveAgentJourneyTests.swift)。
- [Debug fixture 入口](../../Apps/iPhoneApp/Bootstrap/PhoneUITestConfiguration.swift)、[详情显示](../../Apps/iPhoneApp/Features/RecordingDetail/RecordingDetailView.swift)、[来源摘录/失败文案](../../Apps/iPhoneApp/SharedUI/SourceLinksView.swift)。
- [缺口覆盖](../../Packages/MoMoAgentKit/Tests/MoMoArchiveTests/ArchiveCoverageTests.swift)、[时间/过期](../../Packages/MoMoAgentKit/Tests/MoMoArchiveTests/TranscriptLocationTests.swift)、[Files 恢复](../../Packages/MoMoAgentKit/Tests/MoMoArchiveTests/RecordingFileRecoveryTests.swift)、[原生播放故障](../../Tests/iPhoneIntegrationTests/AudioPlaybackIntegrationTests.swift)。
