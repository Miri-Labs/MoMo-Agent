# iPhone v8 UI 交付与验收记录

2026-10-16，本轮 UI 代码与核心软件回归已完成，最终产品源码为 `00ceb2582da91fea3211117bf64c1386a55195f1`。Release05 已通过产物检查、实际安装和无测试参数启动；[最终首页实屏](evidence/2026-10-16-iphone-v8-acceptance/release05-normal-launch.png)与[最终证据索引](evidence/2026-10-16-iphone-v8-acceptance/final-ui-release05-evidence.json)对应这份源码。Git 集成状态以 `main` 和本任务分支的实际提交为准。

任务分支 `codex/iphone-v8-acceptance` 从 main `d45b6d9` 开始，工作快照为 `c45ef2c`；时间线已合并至 `1b5a52d`，新版原生 landing（main `1d3b806`）合并于 `fcd9945`。下文保留各轮来源、失败及后续修正，不宣称 220 个场景全部通过或完整 v0.1 完成。

## 用户最新反馈

- 首页导航移除 App 名字，保留灰色 Apple Watch 图标和真实状态；整组仍可进入转录。原始品牌图标在顶部，中央为实际接入上游运行时代码的非圆 Avatar，布局按用户反馈上移，见[最终 Release05 首页](evidence/2026-10-16-iphone-v8-acceptance/release05-normal-launch.png)。该图来自无测试参数启动，显示「等待手表状态」，不代表真实配对完成。较早[合并首页](evidence/2026-10-16-iphone-v8-acceptance/home-avatar-gray-status-build31.png)与[灰色状态入口](evidence/2026-10-16-iphone-v8-acceptance/home-gray-status-build22.png)保留；后者的录音状态来自隔离测试夹具，不是真机采样。
- 用户再次确认播放器的点阵设计。主播放器、迷你条及引用片段保留真实振幅点阵；黑色手表状态卡与回听播放器的数据职责分别保留。[点阵播放器实屏](evidence/2026-10-16-iphone-v8-acceptance/timeline-dot-player-build25.png)为真实模拟器运行，不是设计稿。
- 用户报告实际佩戴设备上，十点的录音到十二点仍显示「正在转写」。代码确认默认策略是 `foregroundOnly`，锁屏后台暂停，回到前台继续；未据此直接断言此次真机根因。设备当前在开发机上为 unavailable，尚未读取实际运行队列。
- 另确认两个真实显示缺口：普通自动转写每个窗口完成后没有立即发布完成计数；Runtime 只在整队列 idle/waiting 时刷新档案，暂停后也可能回退到旧的 processing 缓存。现于真实提交后发布进度，逐窗刷新 Library；停止状态在原生工作返回后刷新。运行中不逐窗扫描整个档案或执行保留清理。
- 列表和详情共用调度状态映射：只有匹配本次录音且原生正在 preparing/transcribing 时才显示运行；其他录音等待处理，系统挂起显示稍后继续，已完成内容不受全局暂停误标。后台调度策略没有改为已验收的后台持续推理。

## 同轮修补

恢复上次选中会话、未发送文字与来源，以及每会话阅读位置；未获准入的发送在重启后恢复草稿，不自动重发。无法读取界面状态时保留原文件并说明，来源仍校验版本和删除屏障。

非空历史读取、订阅不再要求模型配置或 Keychain。首次生成在同一 Harness 注册 Provider，保持原有订阅；缺失、损坏或缺 root 的真实数据库不能伪装为空历史。`durableStoreCreated` 区分首轮尚未准入的空档与已有档案丢失，兼容旧元数据，取消状态保持持久且不自动重试。

服务字段本地错误留在可编辑表单，展示经过验证的请求基础地址、保存的模型 ID 和鉴权边界。非成功 HTTP 响应仅从 400/404/422 的 JSON 有界提取模型不存在/拒绝提示：最多 8 KiB、1 秒，既有更短期限与取消仍优先；不保存原始错误正文。未知 404、鉴权和限流保持各自分类。SDK JS 已重建并固定 bundle 哈希，来源记录同步。

部分原音不可用时，导出实际可用子集并在清单说明缺失/过期范围；完整库存、lease、哈希、版本与删除校验保留。辅助功能逐步定位可以跨过较长缺口到下一真实可播放范围。抽屉关闭按钮只占露出的遮罩区域，大字号仍留 44pt 关闭区域，并支持读屏 escape。

设置页系统对比度审计发现次要文字在 `#F1F1F1` 表面上不足，浅色 muted 从 `#707070` 调整为 `#686868`，原生和 Web 统一；深色 token 保留。

## 各轮证据

原始证据根：本 worktree 的 `tmp_agent_output/iphone-v8-acceptance-20261015/`。所有失败与中断保持原样；轮次不能相加成全量通过。Xcode 27 / iOS 27，ad-hoc 签名。当前使用专用 AC2 iPhone 17 Pro 模拟器；393pt 设备被另一个开发任务使用后，主动中断本任务的冲突轮次并迁移。

| 轮次 | 实际结果与范围 |
| --- | --- |
| package-agent-archive-04 | Archive 106/106；Agent 72 个测试中 1 个百炼在线用例跳过，其余通过。真实本地持久化、受控传输，不是公网服务质量验收。 |
| provider-model-classification | JS 42/42、类型检查与 bundle 重建通过；bundle SHA-256 `6a174e960667b80d794fe66ac3711164356089b991d5ce425f5c948b16d69537`。最初缺依赖未执行与两个夹具错误均保留。 |
| build18 / 393-hosted-01 | 构建成功；67 用例中 66 通过，阅读恢复实滚动用例失败。Draft 24、Audio 19、WK 9、Provider 9 均在此轮通过，不代表后来所有源码。 |
| build19-ac2-01 | 构建成功；HTTP 表单拒绝与草稿重开、4 个首页手表状态通过。阅读恢复、初版 AX 尺寸断言和新重启 UI 失败均保留。 |
| build20 | 测试构建失败：测试模块和 App 同名 Snapshot 类型混用，随后显式限定 App 类型；未把此轮记为通过。 |
| build21-hosted-01 | 15 用例中 14 通过；ModelRecovery 6/6（含真实首窗完成、第二窗门控、后台取消后缓存恢复）、Provider 模型错误 2/2、Library 其余 6/6。阅读恢复仍失败，原始记录保留。 |
| build21-ui-01 | 7 用例中 6 通过。冷启动恢复选中会话与草稿、HTTP 表单与 4 个状态入口通过。首页和抽屉系统命中/对比度/描述/裁切审核通过；设置次要文字对比度失败。 |
| build22-focused-01 | 构建成功；首页/抽屉/设置四类系统可访问性审核、灰色状态入口 2/2 通过；逐窗进度与后台缓存回归再次通过。阅读恢复仍有两个绝对 offset 断言失败，正在核对实际段落视口与 Lazy 布局估计，不能称为修复。 |
| build23-reading-01 | 构建成功，587 个源输入核对无漂移；真实滚动、销毁重建恢复、追加正文 1/1 通过。严格等待保存段实际可见、恢复意图清除后，再断言同一段 viewport 位置/高度变化不超过 4pt；三阶段截图和原始 offset/contentSize 保留。 |
| chat-core-05 | 聊天核心 Node 检查通过；不是实际 App 或 VoiceOver 验收。 |
| build24-merge-hosted-01 | 合并后的测试构建成功，595 个源输入；46 个用例中 44 个通过。离线历史测试仍使用旧的「无 Provider 则拒绝阅读」合同，断言和未释放 owner 导致同一用例失败；旧详情的阅读恢复也再次失败，真实轨迹确认单次 ScrollViewReader 定位因 Lazy 高度估计停在错误段，不能以 build23 一次通过称为稳定。两个问题分别修正测试合同与生产滚动方式后，等待 build25 验证。未匹配的两个 selector 没有执行，不计入通过。 |
| package-merge-agent-archive-05 | Archive 115/115；Agent 76 个测试含 1 个百炼在线跳过，其余通过。包含时间窗、多来源离线/重试/再生和删除/修订屏障。 |
| package-merge-agent-archive-06 | Archive 116/116；Agent 76 个测试含 1 个百炼在线跳过，其余通过。新增真实 legacy failed job 的修订/标点迁移后显式重排回归（2 个参数场景），失败状态及原音保留，不自动重试。 |
| build25-merge-hosted-01 | 构建成功；90 个用例中 89 个通过。Draft 30、Audio 23、Library 8、ModelRecovery 6、ProviderModel 2、ProviderService 9、Credential 3 全部通过；ChatRenderer 9 中 1 个阅读恢复用例失败。失败在测试拿到前一次2639pt桥接回调，却将其当作刚滚到500pt的保存结果；后续加入接收序号与严格2pt新回调等待，生产 Web 未改，待新构建验证。旧详情改用 ScrollPosition 的真正恢复/追加用例在本轮通过。 |
| build25-merge-ui-01 | 首页/抽屉/设置系统可访问性与重启恢复 2、时间线日期/多来源播放/大字号 4、首页手表状态 4，共 10/10 通过。合并后的真实模拟器截图：[灰色状态首页](evidence/2026-10-16-iphone-v8-acceptance/home-gray-status-build25.png)、[点阵播放器](evidence/2026-10-16-iphone-v8-acceptance/timeline-dot-player-build25.png)；内容与状态均为隔离测试夹具。 |
| build25-recording-export-ui-01 | 6 个完整 UI 旅程中 5 个通过：分享取消重开、播放器操作、Files 原稿预览恢复、无语音原音重启保留、自动转写通过。真实 ASR→回听→原音保留→标记→引用旅程在引用类型断言中断，未到删除步骤；发现 TimelineDetail 将「管理原始录音」的单录音讨论错误转换为精确时间窗数组，改变了上下文范围。保留原测试预期，修正生产路由后待重跑。 |
| release-verifier-selftest-02 | 17/17 自检通过；新增时间线/手表状态 Debug 入口及阅读诊断标识扫描，不等于新 Release 产物已验收。 |
| build26-reading-hosted-01 | 构建成功，596 个输入无漂移；20 个用例中 19 个通过。Library 8/8、新时间线阅读 3/3，包含真实滚动/销毁重建/追加、第二来源变代和旧布局回调。ChatRenderer 阅读用例取得真正500pt回调后，切换短会话又出现 DOM 高度等于视口却报告500/740pt的实际越界，保留失败轨迹继续修补，不能把瞬间0pt当成稳定恢复。 |
| build26-source-timeline-ui-01 | 5/5 通过：真实本地 ASR→回听→原音保留→标记→单录音引用→移除→重启→删除完整走通；4 项时间线日期、多来源播放、引用移除与最大字号通过。新详情仍使用原有点阵播放器。此轮不依赖真实外部 API。 |
| release-verifier-selftest-03 | 加入 TimelineReadingDiagnostic 后的 17/17 自检通过。 |
| build27-reading-hosted-01 | 构建成功；源输入核对仅 Web chat.js 与其测试相对 build26 改变。20/20 通过：WK 9、Library 8、新时间线阅读 3。实际跟随和恢复使用 `max(0, scrollHeight-innerHeight)`；暂时越界时保留上次合法位置，等待真实稳定后再保存，不伪钳坐标。测试同时要求操作后的新桥接回调与当前 DOM 位置都严格匹配；切短会话回到0、重建/切回500pt及追加不抢阅读均通过。 |
| build27-reading-repeat-01 | 三条真实阅读路径各重复 3 次，8/9 通过：聊天3/3、旧录音3/3、新时间线2/3。失败不是绝对 offset：目标段已回到视口，但 Lazy 缓存行曾短暂被逐行几何标为 visible，后续没有 false/消失回调，旧 ID 污染保存锚点。继续修补可见集合的所有权，保留同段可读与追加4pt要求。 |
| ios-release-build-02 / ios-release-bundle-02 | build27 来源的 Release 构建、19/19 产物检查通过，包含嵌入 Watch、固定模型和扩展 Debug 标识检查；之后的阅读集合修补尚未覆盖，不能作为最终源码的 Release 结论。 |
| build28-reading-repeat-01 | 20 项各重复3次，53/60 次通过；14条失败断言对应7次失败运行。旧录音与新时间线恢复各0/3：原生可见目标聚合回调在同帧更新警告后停在估算中间态，虽然目标段最终实际可读，集合仍指离屏段；此候选未修复。另有1次 WK 到达真实底部后旧偏移回流导致不再跟随，已据日志定位单方向 handler 漏掉向下到达底部的重新跟随规则，等待后续构建。 |
| ios-release-build-03 / ios-release-bundle-03 / release-verifier-selftest-04 | build28 来源的 Release 构建、19/19产物检查与17项检查器自检通过；运行时阅读问题仍按上一行保持失败，不由 Release 构建抵消。 |
| build29-reading-repeat-01 | 四条路径各重复3次，聊天两条6/6通过（含新增真实WK顶部/底部往返）；旧录音与时间线恢复各0/3，下一主线程轮次投递候选未解决原生目标集合停滞，已移除该无效投递机制。 |
| build30-narrow-reading-repeat-01 | build30测试构建成功，597个源输入；改用视口内统一解析段落 anchor bounds，测试门槛未降低。独立375pt设备首次启动后本机可用空间降至约700MB，WK初始化未成功，主动中止，exit75；不将环境失败记作阅读正确性结论。已删除仅本任务创建的F128测试设备，并保留原始日志/结果；其它任务正在使用AC2/393设备，未覆盖其App。此候选尚待资源允许后的原生复验。 |
| build31-native-reading-repeat-01 | 合并新版 landing 后构建成功，598个源输入；旧录音0/3、新时间线2/3通过，合计2/6。统一 bounds 的同步 onChange 仍出现同帧更新限制：失败时目标段实际已归位，而可见集合停留在估算布局。旧详情另改为正式装入后的身份令牌，顶部播放器按真实bounds排除遮挡；未因此称为修复。 |
| build31-landing-status-ui-01 | 7/7通过：合并后首页/抽屉/设置系统可访问性审核、冷启动草稿恢复、完整三情境首次体验至首页/转录及重启、四项灰色手表状态入口。未声称覆盖真实穿戴设备。 |
| chat-core-07 | 当前13项渲染核心断言通过；与真实WK阅读重复用例的证据分别记录。 |
| build32-native-reading-repeat-01 | 构建成功；旧录音长段1/3、短段0/3、新时间线0/3，合计1/9。可取消task候选也未消除最终集合停滞，未作为修复接受。新增短段用例还真实证实目标约82pt高、固定播放器约104pt高，直接滚到顶部会把目标盖住；测试仍要求在遮挡之外可读超过44pt和追加4pt内稳定，后续修补保持这些要求。 |
| build33-native-reading-repeat-01 | 改为专门的onGeometryChange统一解析并直接记忆，按真实视口与播放器高度计算一次恢复anchor，8/9通过。旧录音长/短段各3/3，时间线2/3；唯一39pt比较失败的轨迹证实移动发生旧layout/旧revision/旧contentSize下，在新正文loaded-append之前，是基线采样早于原生最后一次校正。原始失败仍保留。 |
| build34-native-reading-repeat-01 | 与build33生产源码完全一致，仅两份测试加强基线和最终帧的连续3次≤0.25pt稳定检查，截图之后重新采样，原44pt与追加4pt要求不变；三条路径各3次，共9/9通过。此结果不替代下一行的完整类回归。 |
| build34-reading-regression-01 | ChatRenderer9/9、TimelineReading3/3、LibraryPagination8/9，共20/21通过。旧录音长段在recreate后未到保存的第13段：一次定位经Lazy估算跳到18/19后停在8/9，pending未清，是实际目标未解析，不能由定向9/9掩盖。保留原测试，后续核对持续绑定目标的原生行为。 |
| build35-reading-regression-repeat-01 | 声明式UUID绑定候选构建成功，21项各重复3次，60/63通过：WK27/27、Timeline9/9、Library24/27；旧长段2次恢复失败，短段1次追加等待失败。绑定候选未解决，且增加短段退化，已撤回到build33/34的原生ScrollPosition机制，不保留无验证收益的另一套状态。两处不存在的SF Symbol改为有效waveform，保留。原始63次证据全部保留。 |
| build36 | 撤回未通过候选后的测试构建成功，598个源输入核对无漂移；生产源码相对build33仅两处SF Symbol字符串变化，测试采用build34更严格的稳定采样。此轮只构建，未声称新一次运行通过。冻结输入见[清单](evidence/2026-10-16-iphone-v8-acceptance/build36-source-inputs.json)，真实未解析轨迹另保留[可迁移副本](evidence/2026-10-16-iphone-v8-acceptance/recording-target-unresolved-build34.txt)。尚未构建新的最终Release。 |

阅读恢复的原测试还混入了错误测量：未等目标段真正出现便开始追加，且 LazyVStack 修正离屏高度估计后绝对 contentOffset 会变化。build23 改用实际同段视口位置并严格等待，未放宽“同段可读、追加不跳读”要求。生产使用可见段几何跟踪、消失清理和仅恢复时主动定位；DEBUG 轨迹不包含正文或原音。测试清理等待模型、播放与 Archive 实际释放后才删除隔离目录，避免移除仍打开的 SQLite。

系统原生工具栏的 AX 可见矩形为 36pt，不能直接等同扩展命中区。后续采用未过滤问题的系统 `hitRegion` 审核并实际点击导航；自定义控件仍测量至少 44pt。不声称已测得原生按钮物理触摸边界恰为 44pt。

较早打开 VoiceOver 后操作抽屉的证据只显示焦点返回菜单，不包含实际朗读音频。后续 player-voiceover43 已通过真实 iOS VoiceOver 服务与单指手势验证播放器，详情和实际播报文本见下节；仍不代表全部流式回复或全 App 的读屏验收。

## build41–43：真实导航、读屏与剩余失败

本节以实际运行日志为准，原日志大小和 SHA-256、逐轮范围及可迁移附件列于 [41–43 证据报告](evidence/2026-10-16-iphone-v8-acceptance/build41-43-progress.json)。构建前源输入原样保存：[build41，606 项](evidence/2026-10-16-iphone-v8-acceptance/build41-source-inputs.json)、[build42，606 项](evidence/2026-10-16-iphone-v8-acceptance/build42-source-inputs.json)、[build43，607 项](evidence/2026-10-16-iphone-v8-acceptance/build43-source-inputs.json)。这些是构建前快照，本节不据此另称构建前后全部输入一致。

| 轮次 | 实际结果与范围 |
| --- | --- |
| build41 | 测试编译失败：嵌套 `private ReadingNavigationPath` 无法被 `@Observable` 生成的外部扩展访问。改为 `fileprivate` 后进入 build42；失败日志保留。 |
| build42 / reading-native42 | 构建成功。旧录音三条路径各重复 3 次，共 **2/9 通过、7 次运行失败**：同一 NavigationStack 真实 pop/push 长段 1/3、替换控制器重建长段 1/3、固定播放器下短段 0/3。XCTest 的 14 条失败/异常记录不是 14 个用例。Timeline selector 拼写不匹配，实际执行 0 项，不能计为通过。 |
| watch-status42 | 宿主 **9/9**：收件状态 5、选中手表域 3、状态显示 1。C109 的 selected-Watch 目录、activation 代次、回调顺序、缓存新鲜度、旧域错误和删除屏障已有软件回归；不代表真实配对切换或 WatchConnectivity 传输端到端验收。 |
| watch-status package-tests-01 | 独立 worktree 中 SelectedWatchContext 2/2 与 ArchiveStatus 7/7，合计 9 个不同包用例通过；两个过滤运行分别保留，不冒称同一全量套件。 |
| controlled-ui42 | 两条全 App 受控流式旅程 **0/2**。当时读取的两份隔离 ledger 均为 schema 2、launches 1、launchRequestCounts `[0]`、requests/events 0；没有生成请求，不能据此接受停止、重试、重新生成或引用回听。事件与失败层级证实键盘重排后仍点击旧发送坐标；仅测试交互已修正，尚待重跑。没有完整 ledger checker 通过报告。 |
| build43 / reading-native43 | 构建成功。旧录音同一 NavigationStack pop/push、销毁重建长段、固定播放器下短段各 **3/3**；真实 WK 导航策略 **3/3**，共 **12/12**，XCTest 17.388 秒。此轮不包含 Timeline 同类修补及下一次完整基线。 |
| player-voiceover43 | 375pt、iOS 27 模拟器，真实 VoiceOver 服务与单指上下轻扫 **1/1**，60.202 秒。正式时间线音频先播放再暂停，读屏聚焦可调进度后从 00:01 调至 00:02，再调回 00:01；实际播报同时包含总长 00:11。退出后恢复原先关闭状态。 |
| 375pt-dark-keyboard40 | 较早同轮 4 项中 2 通过、2 失败；其中普通字号与辅助字号的真实软件键盘两项 **2/2**。当轮首页审计和最大字号时间线的失败保留，不记为整轮通过。 |
| 375pt-dark-audit43 | 最大辅助字号 AX5 时间线 **1/1**。另一个组合审核用例完成首页/抽屉后，在设置「储存空间」报 Contrast failed，因此整轮 **1/2**；与较早远程 AX 启动失败不同。 |

reading-native42 的两种长段重建都出现目标未挂载，说明问题不能只归咎于替换控制器的测试方式。短段三次均已恢复到播放器下方，最终正式文档 version 2 和真实段落帧正确；失败来自测试要求 Lazy 估算的 contentSize 必须增长，而实测由 8900 变为 8896。后续仅将这一条件改为正式文档版本和新增段数准入，保留可读超过 44pt、同一身份、连续稳定采样以及追加前后 ±4pt 的要求。

build43 将旧录音的一次恢复命令移到原生 `onScrollGeometryChange` 阶段，在当前文档准入、真实视口和锚点均就绪后执行。3 条严格路径各重复 3 次通过，属于改善证据；Timeline 的对应迁移和完整类回归仍待下一轮，不提前关闭偶发恢复问题。

同轮修复 WKNavigationDelegate 回调签名缺少 SDK 要求的 `@MainActor @Sendable` 导致运行时 selector 未注册的问题。新测试先验证正式 delegate selector，再让实际 WK 主帧尝试 HTTP、HTTPS 和已授读取权限的外部 file 导航，要求被拒绝且原 DOM 保留；正式 bundled bootstrap 重载仍允许。来源桥与 CSP 未放宽，不用网络失败代替策略阻断。

VoiceOver 的[聚焦实屏](evidence/2026-10-16-iphone-v8-acceptance/player-voiceover43-focused.png)、[向上调节](evidence/2026-10-16-iphone-v8-acceptance/player-voiceover43-incremented.png)、[向下调节](evidence/2026-10-16-iphone-v8-acceptance/player-voiceover43-decremented.png)与[实际播报文本](evidence/2026-10-16-iphone-v8-acceptance/player-voiceover43-utterances.txt)已原样保存。文本来自 `VoiceOverService.currentSpeech`，不是预写的期望值；它是服务返回的 utterance，并非录下的朗读音频。测试在暂停状态调节，避免把播放自然前进当作 seek；[隔离说明](evidence/2026-10-16-iphone-v8-acceptance/player-voiceover43-isolation.txt)记录未启用 ASR、模型配置或网络参数。该结论限定于这一真实播放器路径，不覆盖全 App VoiceOver 或 Reduce Motion。

深色设置的[系统失败截图](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit43-failed.png)、[被标记元素](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit43-element.png)和[原始 issue](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit43-issue.txt)继续保留。元素图中实心文字为 `#F2F2F2`、背景为 `#292929`，按 sRGB 算得约 13:1；这尚不能解释系统审计为何失败，也不能据此宣布误报。未改主题、未过滤该 issue，下一轮原样复验。[AX5 时间线实屏](evidence/2026-10-16-iphone-v8-acceptance/timeline-375pt-ax5-build43.png)对应本轮实际通过用例。

## build44–45：完整阅读回归与受控 App 闭环

本节是后续独立记录，[44–45 证据报告](evidence/2026-10-16-iphone-v8-acceptance/build44-45-progress.json)保留各原日志 SHA、checker 首次失败及最终报告、系统审计完整 issue 和限定的人工像素核查；此前 [41–43 报告](evidence/2026-10-16-iphone-v8-acceptance/build41-43-progress.json)不重写。

| 轮次 | 实际结果与范围 |
| --- | --- |
| build44 / reading-full44 | 测试构建成功，构建执行者核对 610 项输入无漂移；[构建前清单](evidence/2026-10-16-iphone-v8-acceptance/build44-source-inputs.json)另存。完整阅读相关类共 23 项，**22 通过、1 失败**：Library 10/10、Timeline 3/3、WK 9/10。唯一失败为 touchcancel 测试过早将 scrollTo 的临时 DOM 底部值当成原生完成，随后向上操作被首次原生滚动覆盖；失败发生在 touchstart/cancel 前，原记录保留。 |
| controlled-ui44 | 实际整 App 两条受控流式旅程 **2/2**，XCTest 140.466 秒。覆盖已收到回复后停止、新草稿保留、围绕原问题重新生成、503 后重试、正式来源引用/回听，以及流中断、过期原音仍能阅读原文、重启不额外发送。使用正式 Pi/Archive 配合隔离 URLProtocol；不等于公网模型质量或 ASR 验收。 |
| controlled-ui44 checker-03 | 同两份冻结持久化证据独立只读检查：A **35/35**、B **31/31**；checker 合成自检 **15/15**，不计作额外 App 旅程。首份 A 检查报告失败原因及原 SHA 保留，见下文。 |
| 375pt-accessibility44 | 共 6 项，**4 通过、2 失败**。四项手表状态入口/陈旧状态/大字号/可关闭错误横幅全部通过；设置「储存空间」对比度继续失败。Reduce Motion 在真实系统设置的根页面识别上失败，尚未验证 App 行为。 |
| build45 | 测试构建成功；[构建前清单](evidence/2026-10-16-iphone-v8-acceptance/build45-source-inputs.json)含 610 项。编译期间授权修改了两个 Python checker 脚本，均非 Xcode 编译输入；其余 Swift/Web/project 保持冻结，不能称这份宽范围清单的全部 610 项无变化。 |
| reading-full45-repeat | 23 个不同阅读相关用例各运行 3 次，**69/69、0 失败**：ChatRenderer 30/30、LibraryPagination 30/30、TimelineReading 9/9；测试 40.364 秒，Xcode 报告总历时 49.576 秒。包括真实 pop/push、销毁重建、短段播放器遮挡、多来源版本屏障、追加不抢阅读和 WK 导航/跟随。不是全部 220 个场景或全部 App 回归。 |
| 375pt-accessibility45 | 两项均未通过。设置仍报同一对比度问题；新 handler 原样保存 issue、返回 false，不忽略失败。Reduce Motion 已进入正确「动态效果」页面，但点击开关后未成功开启，测试保留失败并恢复原先关闭状态，不能将这轮记为 Reduce Motion 验收通过。 |

build45 对 touchcancel 仅修测试前置：同一 session 首次正文到底后，必须同时取得新 bridge、真实 scroll/scrollend、DOM 与 WK 原生 offset/contentSize 一致，才唯一执行滚到顶部；顶部再要求新 following=false/0 坐标。原 touchstart/cancel、回到底部和追加跟随断言保留，未改生产滚动逻辑。此修正已由上述 69/69 重复运行覆盖。

受控旅程 A 的[首次失败报告](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui44-checker-a-original-failure.json)没有删除：第三次 HTTP 请求的事件实际为 `headers-503 → body(40 bytes) → cancelled`，原检查器只接受 `http-503` 终态。最窄修正允许这一路 HTTP 错误处理后的单一取消终态，但仍要求 503 headers、服务端正数字节、正确顺序且终态后无正文，并独立读取 Pi 持久诊断，确认 HTTP 503、HTTP attempts 2 和同一 regeneration operation。最终 [A 报告](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui44-checker-a-final.json)、[B 报告](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui44-checker-b-final.json)、[汇总](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui44-checker-final-summary.json)与 [15 项自检日志](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui44-checker-selftests15.log)均原样保存。

服务器夹具写出 40 字节不表示客户端已读取这 40 字节。独立只读 Pi entry 18 的诊断为 `receivedBodyBytes=0`；正式客户端在 503 响应后取消。A/B 的不可变原始用户记录分别为 3/2，投影后各只有 1 个逻辑问题，不能把再生与重试的底层记录数误称为重复可见用户消息。该记录形成时首字前停止的新第三场景仅已编译，因此这一轮只接受两条旅程；后续 45 三场景运行单独记录如下。

设置对比度复核限定于 375pt 深色静止页面。43/44 的失败元素图字节完全相同；两轮审计前和失败时整页内容区域均没有像素变化。[44 审计前](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit44-before.png)、[失败时](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit44-failed.png)和[元素图](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit44-element.png)支持这个限定观察。实心文字/背景约 13.00:1，箭头约 6.26:1；储存行没有异步数值、disabled 或 opacity，保留天数加载属于上方独立行且截图已显示 7 天。45 的[完整 issue](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit45-full-issue.txt)定位到 `settings.storage` 按钮下的 StaticText，frame 为 `(24,530,327,58)`；[失败截图](evidence/2026-10-16-iphone-v8-acceptance/settings-dark-audit45-failed.png)保留。尚未找到确定的 App 低对比缺陷；系统审计 43/44/45 仍记为失败，不能宣布工具误报或全 App AA 通过，不猜测改色或过滤 issue。

## controlled-ui45：三条受控整 App 旅程

375pt 模拟器上的三项实际 UI 测试 **3/3、0 失败**，XCTest 183.228 秒，Xcode 报告总历时 190.196 秒。此轮使用新隔离 run，不把旧 44 轮证据改为本轮结果；日志 SHA、检查报告和代表实屏见[独立 45-CUI 报告](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-progress.json)。完整隔离快照保留在 `controlled-ui45-snapshot-container`，不依赖后续可能迁移的可变 App 容器。

| 场景 | 实际 UI 与持久化证据 |
| --- | --- |
| A：收到部分正文后停止、原问题再生、503 后重试、引用回听、重启 | UI 68.313 秒通过；[独立 checker 35/35](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-checker-a.json)。正式 Pi/Archive 的请求身份、重试次数、来源、最终投影、草稿和重启不重发均核对。 |
| B：流中断重试、过期原音来源仍能阅读和讨论、重启 | UI 64.072 秒通过；[独立 checker 31/31](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-checker-b.json)。两份正式来源均按原音保留规则清理，转录版本和引用阅读保留。 |
| C：首个响应 body 到达前停止、保留新草稿、重启不重发 | UI 50.843 秒通过；[独立 checker 27/27](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-checker-c.json)。实际只有 1 次持久准入，metadata 为 cancelled，未回答的 submission 已 aborted、assistantMessages 0；重启后仍是 1 个逻辑问题和原草稿。这是已准入请求的首 body 前取消，不冒称未准入取消。 |

代表实屏已逐张读取并保存：[停止后保留正文与新草稿](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-stopped-with-draft.png)、[正式引用片段原生播放](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-source-playing.png)、[原音过期但原文可读](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-expired-source.png)、[首 body 前取消后的重启](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-no-body-cancel-relaunched.png)。过期来源图的播放器禁用并显示清理说明，同时仍保留波形准备占位文案；不将截图描述成该占位已消失。播放截图证明当前原生控件状态，不单凭图片宣称已做人工听音。

检查器的 [A/B 汇总](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-checker-ab-summary.json)与 [C 汇总](evidence/2026-10-16-iphone-v8-acceptance/controlled-ui45-checker-c-summary.json)绑定各自冻结输入哈希。35/31/27 是独立持久化检查数，不能算成额外 UI 用例。此轮为正式 App + 受控 URLProtocol 合成回复，不增加公网模型质量、真实 ASR 或全部 220 场景通过的结论。

## build46–47 与最终 Release05

最终[证据索引](evidence/2026-10-16-iphone-v8-acceptance/final-ui-release05-evidence.json)保存原日志大小与 SHA-256、构建源清单、产物检查、签名、Web 资源和安装报告的原样副本。此前失败与截图不覆盖。

| 轮次 | 实际结果与范围 |
| --- | --- |
| player-reduced-motion46 | 真实系统「减弱动态效果」开启后，正式时间线播放器播放、暂停、seek、继续与同源迷你播放器 **1/1**，XCTest 58.595 秒、总历时 66.841 秒；最后恢复系统原先关闭状态。此前 44/45 的设置操作失败仍保留。[报告与 5 张实屏](evidence/2026-10-16-iphone-v8-acceptance/reduced-motion46-evidence.json)记录系统开关和实际播放器状态；这不是全 App 动画审计。 |
| expired-source-ui47 | 仅将无可用波形时的占位改为事实性「暂无可用波形」，避免不可播放时误称正在读取。B 完整旅程 **1/1**，85.415 秒，独立持久化 checker **31/31**；原文仍可阅读，原音不可用时播放禁用。[报告](evidence/2026-10-16-iphone-v8-acceptance/expired-source47-evidence.json)与[新实屏](evidence/2026-10-16-iphone-v8-acceptance/expired-source47-unavailable-waveform.png)对应此改动；45 的旧占位截图保留，47 未重跑 A/C。 |
| Release04 | 在全新 `DerivedDataReleaseV8-02` 构建成功，来源 `11d3fb8`；构建执行者在改占位前核对 610 项输入无漂移。它与 build46 的源清单完全相同，不冒称这些旧输入仍全部匹配改文案后的当前源码。 |
| Release05 | 同一 DerivedData 增量构建成功，来源 `00ceb25`；相对 Release04 唯一源差异为上述占位文字。**19/19** 产物检查、检查器 **17/17** 自检、**40/40** Web 源与包内字节匹配；签名验证为 valid on disk 且满足 Designated Requirement。检查包括手机、嵌入 Watch、4 份固定模型资源，以及 Debug 入口、测试假 key 和 fixture 排除。 |
| Release05 实际安装/启动 | 安装到专用 AC2 iPhone 模拟器，以空参数正常启动；观察到进程 88949 的命令仅为 Release 可执行文件。手机与嵌入 Watch 的可执行文件、Info.plist 共 **4/4** 安装前后哈希匹配。实际查看首页确认顶部原 logo、灰色手表状态、无 App 名标题、中央非圆 Avatar 和上移构图；不等于 Watch App 已启动。 |

四份 610 项清单原样保存：[build46](evidence/2026-10-16-iphone-v8-acceptance/build46-source-inputs.json)、[Release04](evidence/2026-10-16-iphone-v8-acceptance/release04-source-inputs.json)、[build47](evidence/2026-10-16-iphone-v8-acceptance/build47-source-inputs.json)、[Release05](evidence/2026-10-16-iphone-v8-acceptance/release05-source-inputs.json)。独立比较确认 46=04、47=05，跨版本仅 `AudioPlayerView.swift` 一行占位差异；47/05 的 610 项与收尾时当前文件全部匹配。各构建开始前已冻结源码，最终核对后继续冻结。

[19 项检查](evidence/2026-10-16-iphone-v8-acceptance/release05-bundle-checks.json)、[Web 清单](evidence/2026-10-16-iphone-v8-acceptance/release05-web-sources.json)、[签名日志](evidence/2026-10-16-iphone-v8-acceptance/release05-signature.log)、[安装及无参数启动](evidence/2026-10-16-iphone-v8-acceptance/release05-installed-and-launched.json)分别保留其适用范围。Release04 是全新构建，Release05 是单行改动后的增量构建；它们都不是从干净 Git clone 的复现或 App Store archive。

## 交付范围与后续边界

- 本轮 UI 实现与核心软件回归已完成，最终产物也已检查、安装和正常启动；产品源码与本记录分别提交，合并状态以 Git 为准。
- 完整阅读相关类在 build45 各重复三次 69/69 通过，受控整 App 三条闭环在 45 通过，Reduce Motion 在 46 通过，单行占位更新后的 B 在 47 通过。不同轮次不相加成全量通过，旧失败继续保留，44pt、追加 4pt 和会话/来源身份门槛不变。
- 220 场景的独立审计不等于全部执行通过。干净检出复现、容量边界、长输入和更多视觉/读屏矩阵属于后续覆盖；本轮不将它们写成已完成项，也不据此扩大交付结论。
- Pencil 的任务文件绑定未能确认，因此没有修改 `.pen` 或覆盖旧设计截图；最终代码按用户最新反馈实现，并用真实 Release 首页交付，绑定核查保留在原始证据根。
- 深色设置系统对比度审计 43/44/45 仍记失败，未过滤；实屏文字约 13:1、箭头约 6.26:1。尚未证实 App 存在低对比缺陷，也不称系统误报或全 App AA 通过。
- 实际穿戴设备的转写积压仍未诊断，需连接设备核对窗口计数和 runtime。`foregroundOnly` 未改变；模拟器显示修补不能替代真机队列、后台调度、WatchConnectivity 或 18 小时采集验收。

## 软件 UI 验证边界

整 App 受控流式三条核心闭环、真实系统 Reduce Motion 的播放器路径、375pt 普通/辅助字号键盘、AX5 时间线及真实 VoiceOver 可调播放器均有各自实际通过轮次，不合并称为同轮全矩阵。C109 已通过选中手表归属的软件宿主/包回归，真实设备切换和传输仍是另一验证层。最终 Release05 的检查与普通启动完成，不增加公网模型质量、真机采样、Watch runtime 或完整 v0.1 的结论。

## 活动归组整合与阅读布局对照

已整合 main `6899ea8` 的说话活动归组（合并提交 `b4276bc`），保留来源准入和阅读身份门槛。修补详情 A→B（开始播放）→C 连续归组时丢失冻结 B 控制的问题；正式 Archive 与原生播放/暂停/继续回归在 build38 连续 3/3 通过。

独立布局对照不等于产品验收：build38 的延迟准入测试因构造闭包内读取 Observation 而没有真正准入，6 次失败原始日志保留；修正测试观察域后，build39 的六组对照共 18/18 通过。build40 分别单独改变条件正文分支与随正文出现的底部栏，两组共 6/6；同轮未改动的原详情销毁重建/追加 3/3。当时新增的同一 NavigationStack 真正 pop/push 对照尚待编译；后续 build42 仍复现未挂载，build43 原生滚动阶段候选才取得三条路径各 3/3，见上节。原范围与日志哈希见 [布局证据](evidence/2026-10-16-iphone-v8-acceptance/layout-probe-progress-20261016.json)，不覆盖或改写旧报告。该布局调查阶段没有新 Release、真机或收费 API 结论；后续最终 Release05 另记于上节。
