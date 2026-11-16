# 每日转录、凌晨折叠与贴纸自然日投影

实现与验证阶段仅修改 `agent/fold-early-transcripts-58b4fd7a8e29` 独立 worktree；Codex 未提交、推送或合并。用户随后明确授权主流程将本功能创建独立 PR 并合入最新 main（不是反方向同步），发布状态以 GitHub 实际记录为准。未部署、安装或启动应用，未操作运行版设置和真实数据库。原图生成只在临时数据库测试中使用假生成器，没有调用生成服务。

已全文核对用户交付的《每日转录与贴纸的一致方案.md》，按用户后续确认采用默认 08:00 折叠，保留“全部展开”。下列是源码实现和自动化证据，不代表已上线或真机验收。

## 行为与兼容选择

- **归日固定为录制地自然日。** 旧 `dayStartHour` 为 0、8、23 均不移动转录日期。旧参数继续接受，`TimelineDay.setCurrentStartHour` 成为兼容空操作，不覆盖旧偏好。
- **阅读偏好独立。** 新键 `timeline.earlyTranscriptHour`，Mac 服务配置为 `runtime/transcript-reading.json` 的 `early_transcript_hour`；默认 8、0 表示全部展开。设置仍按设备保存，本次未增加跨设备偏好同步。旧 `runtime/day-boundary.json` 保留，既有生成调度兼容函数不改成迁移工具。
- **两端每日页顶部保留当天全部贴纸。** 凌晨记录可展开；今日未到界限、只有凌晨记录时默认展开；没有凌晨内容时不显示折叠条。07:59 与 08:01 即使属于同一会话，也划成两个阅读组，白天内容不会一起折叠。
- **进入新日期从顶部开始，后台更新不主动跳日期或回顶部。** 读过日期保留位置；搜索和贴纸来源跳转展开目标。Mac 原文刷新使用请求身份与阅读锚点，过期请求不能覆盖新结果。
- **跨午夜原音不剪切、不复制。** 每日音频索引引用同一 epoch 的不相交帧区间；段落回听仍引用完整原始范围。没有逐字时间戳的整句按开始日期显示一次，不猜字符切点。跨日贴纸可从次日定位到该句实际开始日期；两端共用 `transcriptAnchor(on:)`。
- **跨日贴纸只保留一个 ID。** 主归属为最早来源日期，相关日期引用同图并标记“跨午夜”，不用生成日期归属。来源锚点保留 source/span ID、录制偏移和证据等级。更新来源索引不改图片 hash、请求 ID、生成次数或 ready 状态。
- **时区证据优先。** 转录优先 chunk 的录制偏移；旧 Mac 来源缺证据时保留明确的 `UTC（时区待确认）` 投影。旧贴纸优先录制偏移，其次既有保存时区/窗口；无法解析的内容保留原索引，不盲迁移。若录制证据始终缺失，旧贴纸保存时区与转录 UTC 暂时不同仍属未决，不能认定已恢复真实当地日期。
- **旧缓存兼容。** 新字段均可选；旧手机贴纸缓存升级时仅重放一次 manifest，保留图片。旧手机遗漏时钟字段不会擦除服务已有证据。同 revision 的矛盾时钟被拒绝，文字校验及原 revision 语义保持不变。

## 独立审查缺陷修复

1. `_SOURCE_SKELETON_CACHE` 增加数据库 `sources.updated` 单调元数据戳。缓存使用实际加载 payload 对应的戳，避免并发读取时把旧头信息与新 payload 混作同一个缓存键。测试先预热无时区投影，再在同 generation/version/text 下补传，包含时钟回退、重新连接、跨午夜两段、`read_source` / `build_windows` / `list_sources` 一致性。
2. ready 贴纸 reconcile 核对当前 source 中**同 source ID、span ID、原始 recorded_at** 的稳定时钟，仅补充 `timezone_offset` / `end_at`。不同段落或改动后的起始时间不能借用。更新 evidence、单调 updated_at 并发布 changes 事件，因此已持 cursor 客户端也会发现日期变化。HTTP manifest 在读取前已有 reconcile 路径；补了真实本地 HTTP 回归，未依赖扫描器或完整 manifest 重拉。
3. `LifeIllustrationViewer` 自定义初始化器接收 `referenceDay`。最终 Mac 与 iPhone 编译均成功。
4. 增加客户端持 cursor 元数据增量测试：同 ID 日期更新、原图字节不变、无重复下载、离线缓存恢复与新 cursor 均正确。

## 精确文件清单

| 文件 | 变更 |
|---|---|
| `Packages/MoMoAgentKit/Sources/MoMoContracts/AudioTime/TranscriptReadingBoundary.swift` | 新独立阅读偏好与初次展开策略 |
| `Packages/MoMoAgentKit/Sources/MoMoArchive/TimelineModels.swift` | 自然日、旧参数兼容 |
| `Packages/MoMoAgentKit/Sources/MoMoArchive/Timeline.swift` | 录制地自然日、折叠切分、午夜帧范围、日期上下界 |
| `Packages/MoMoAgentKit/Sources/MoMoArchive/ArchiveModels.swift` | 来源位置增加录制偏移 |
| `Packages/MoMoAgentKit/Sources/MoMoArchive/Transcripts.swift` | 从 chunk 读取来源时钟 |
| `Apps/iPhoneApp/Features/RemoteAgent/PhoneContextSync.swift` | 同版本旧来源时钟补传 |
| `Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/ContextClient.swift` | 可选来源时钟、日期和证据字段 |
| `Apps/MacApp/Context/context_store.py` | 自然日窗口、早晚分组、时钟补传校验、缓存失效 |
| `Apps/MacApp/Context/life_illustrations.py` | 来源日投影、ready 时钟补全及增量发布 |
| `Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/LifeIllustrationModels.swift` | 跨日引用、历史兼容、原句锚点 |
| `Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient/LifeIllustrationCache.swift` | 旧 cursor 一次重放 |
| `Apps/ClientUI/LifeIllustrationStripView.swift` | 跨午夜标记 |
| `Apps/ClientUI/LifeIllustrationView.swift` | 浏览器来源日期与初始化器 |
| `Apps/ClientUI/LifeIllustrationJourneyMapView.swift` | 地图查看来源日期 |
| `Apps/iPhoneApp/Features/Library/LibraryView.swift` | 顶部贴纸、凌晨折叠、来源跳转、保留滚动 |
| `Apps/iPhoneApp/Features/Library/LibraryModel.swift` | 搜索来源录制时区 |
| `Apps/iPhoneApp/Features/Library/TimelineModel.swift` | 日期范围、刷新保持日期与阅读状态 |
| `Apps/iPhoneApp/Features/Library/TimelinePresentation.swift` | 自然日标签、录制地日期范围 |
| `Apps/iPhoneApp/Features/RecordingDetail/TimelineDetailView.swift` | 精确 span 跳转 |
| `Apps/iPhoneApp/Application/Transcribing/PhoneSpeechSettings.swift` | 新偏好，保留旧键 |
| `Apps/iPhoneApp/Features/Settings/SettingsView.swift` | 折叠设置文案、全部展开 |
| `Apps/MacApp/Desktop/DesktopModel.swift` | 新阅读配置、只读默认加载 |
| `Apps/MacApp/Desktop/DesktopTranscripts.swift` | Mac 日期、折叠、贴纸跳转、原文阅读状态 |
| `Apps/MacApp/Desktop/DesktopViews.swift` | Mac 设置文案与选项 |
| `Tests/AgentRuntime/test_context.py` | 同 revision 缓存与来源时钟、午夜、08:00、DST 回归 |
| `Tests/AgentRuntime/test_life_illustrations.py` | 历史 ready、增量 HTTP、来源匹配、原图不变回归 |
| `Packages/MoMoAgentAgentClient/Tests/MoMoAgentClientTests/LifeIllustrationTests.swift` | 旧缓存、跨日原句锚点、同图元数据增量回归 |
| `Packages/MoMoAgentKit/Tests/MoMoArchiveTests/TimelineTests.swift` | 自然日、折叠、帧守恒与文本唯一回归 |
| `Packages/MoMoAgentKit/Tests/MoMoArchiveTests/TimelineExportTests.swift` | 分享区间午夜边界夹具 |
| `Packages/MoMoAgentKit/Tests/MoMoContractsTests/TranscriptReadingBoundaryTests.swift` | 新偏好、旧 0/8/23、展开分支 |
| `Tests/iPhoneIntegrationTests/PhoneSpeechSettingsTests.swift` | 新设置兼容测试（已编译，未执行） |
| `Tests/iPhoneIntegrationTests/TimelineDateNavigationTests.swift` | 顶部首屏、返回位置、自然日测试（已编译，未执行） |
| `Tests/Support/DailyTranscriptProjectionTests.swift` | Mac 纯数据投影、日期范围、真实 archive 后台追加与阅读位置 |
| `Tests/Support/run-daily-transcript-tests.py` | 直接编译生产源码的隔离 SwiftPM 测试探针 |
| 本文 | 决策、命令、证据与未验证边界 |

未涉及另一工单的回车发送或确认通知。版本配置未改；本次不交付安装包。

## 最终实际执行的测试与构建

所有命令从当前 worktree 根目录运行。现有应用内 Python 仅作为已有依赖解释器使用，未启动应用。所有测试数据为临时夹具，HTTP 测试只绑定本地随机端口并使用测试凭据。

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Applications/MoMo Agent.app/Contents/Resources/AgentRuntime/python/bin/python3' -m unittest discover -s Tests/AgentRuntime -p 'test_context*.py' > tmp_agent_output/daily-transcripts/context-tests.log 2>&1

PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Applications/MoMo Agent.app/Contents/Resources/AgentRuntime/python/bin/python3' -m unittest discover -s Tests/AgentRuntime -p 'test_life_illustrations.py' > tmp_agent_output/daily-transcripts/illustration-tests.log 2>&1

PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python '/Applications/MoMo Agent.app/Contents/Resources/AgentRuntime/python/bin/python3' Tests/Support/run-daily-transcript-tests.py --output tmp_agent_output/daily-transcripts > tmp_agent_output/daily-transcripts/swift-tests.log 2>&1

xcodebuild build -project MoMoAgent.xcodeproj -scheme MoMoAgentMac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath tmp_agent_output/daily-transcripts/DerivedData -clonedSourcePackagesDirPath tmp_agent_output/daily-transcripts/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -jobs 2 > tmp_agent_output/daily-transcripts/mac-build-final.log 2>&1

xcodebuild build-for-testing -project MoMoAgent.xcodeproj -scheme MoMoAgent -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath tmp_agent_output/daily-transcripts/DerivedData -clonedSourcePackagesDirPath tmp_agent_output/daily-transcripts/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -jobs 2 > tmp_agent_output/daily-transcripts/phone-build-final.log 2>&1

git diff --check
```

Swift 探针内部实际执行：

```sh
swift test --package-path tmp_agent_output/daily-transcripts/probe --jobs 2 --filter 'Timeline|LifeIllustration|TranscriptReadingBoundary|DailyTranscriptProjection|RemoteContextSync'
```

| 检查 | 最终结果 |
|---|---|
| Python context | 18 通过 |
| Python life illustrations | 52 通过 |
| Swift LifeIllustrationTests | 17 通过 |
| Swift DailyTranscriptProjectionTests | 5 通过 |
| Swift RemoteContextSyncTests | 22 通过 |
| Swift TranscriptReadingBoundaryTests | 2 通过 |
| Swift Archive Timeline / Playback / Activity / Issues / Export / 性能等 7 suites | 42 通过 |
| 自动化合计 | **158 通过，0 失败**，不将重复运行相加 |
| Mac arm64 Debug 完整构建 | `BUILD SUCCEEDED` |
| iPhone arm64 Simulator Debug 测试构建 | `TEST BUILD SUCCEEDED`，包含 SwiftUI 类型检查和测试 target 编译；不是测试运行 |
| diff 格式检查 | 通过 |

Swift 探针链接实际 Contracts、Archive、AgentClient、同步和时间线模型源码；Mac 视图文件仅抽取其实际 Foundation 投影部分供单测。完整 SwiftUI 由上述 Xcode 构建验证，探针不冒充 UI 运行。

编译日志仍有既有 Mac 缩放手势的 actor isolation 警告，以及 AppIntents 元数据提取跳过提示；Python 日志有既有 Pillow 弃用、未显式关闭 HTTPError 的 ResourceWarning。均不是构建或断言失败。

## 尚未验证及保留边界

- 未安装、启动或运行真机/模拟器 UI；首屏贴纸实际可见性、VoiceOver、减弱动态效果、长列表滚动、横竖屏和真实返回手势仍需设备验收。已更新 iPhone UI 测试的旧“默认滚到底部”断言，但本轮只编译。
- 未跑真实 Mac→iPhone 网络增量和断线恢复；已有 cursor 的服务/客户端两端分别自动化覆盖，不能替代跨设备验收。
- “不重新生成”保证历史贴纸像素、ID 和生成状态不变；窗口摘要仍沿用精确文本 fingerprint 的现有匹配/生成机制，折叠分组改变文本范围时可能产生新的窗口摘要请求，不承诺所有摘要永不重算。
- 混合偏移、DST 重复时间通过合成测试；录制 epoch 内若现实跨时区或 DST 而没有新偏移证据，不能推断位置/时区变化。
- 旧数据无法匹配稳定 source/span/start 或缺时区时保留来源和原图；不通过推测迁移历史，不触发历史贴纸重生成。
- 跨午夜整句只展示一次，因此次日贴纸原文入口可能打开前一天该句的起始位置；这是显式保守规则，音频仍覆盖完整原句。
- 构建依赖使用本机已有依赖的 worktree 内副本，无安装、下载或共享目录修改。清理后重新完整构建需再次准备这些本机依赖。

## 产物清理

清理结果与磁盘实测见 `tmp_agent_output/daily-transcripts/cleanup.json`。只删除本轮在当前 worktree 创建的 DerivedData、SwiftPM 探针和依赖副本；保留上述日志与源码 diff。没有清理其他 worktree、共享 DerivedData 或运行目录，也不将 APFS clone 的逻辑大小或其他任务释放空间宣称为本轮实际释放量。
