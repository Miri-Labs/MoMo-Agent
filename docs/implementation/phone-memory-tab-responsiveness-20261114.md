# iPhone 记忆页切换卡顿

用户反馈在转录、聊天和记忆之间切换时，手机偶发整体无响应。本次处理 iPhone 代码中可复现的主线程阻塞；真机未连接，尚未验证用户设备上的偶发情况。

## 原因与修改

`RemoteMemoryView` 的 `vaultTree` 和 `visibleTree` 原先是同步计算属性。页面、工具栏及每个子目录读取它们时，都会重新过滤、排序、构建整棵目录。排序还会解析笔记摘要，超过摘要缓存容量后反复构建目录会反复解析正文。目录内的 `VStack` 则一次性创建全部行。这些工作位于主线程，离开记忆页时发生更新也会阻塞其他 Tab 的交互。

- 新增页面持有的 `RemoteMemoryProjection`，后台生成目录和搜索结果。数据及查询未变化时复用已完成结果；查询变化时复用基础目录。
- 取消及请求代次检查保证旧任务不能覆盖新笔记或新搜索结果。
- 目录中的笔记行改为懒加载；每个 `ForEach` 元素保持单个视图容器，保留目录层级、展开状态、分隔线和全部笔记。
- 排序键每条笔记计算一次，避免在排序比较函数中反复访问或重建摘要。
- 版本配置更新为 `0.6.22`，内部构建号 `113`。

## 验证

环境：iPhone 18 Pro / iOS 27.0 模拟器、系统默认字号，独立合成资料库，1,200 条笔记、12 个子目录，每条 60 行正文。配对服务仅监听 `127.0.0.1:19277`。

以 `011a8a91` 的 `RemoteMemoryView` 页面及 `ClientControls` 实现恢复基线，再用同一 UI 用例和资料库比较：

- 基线首次切入记忆时，XCTest 点击/等待空闲过程约 24 秒；随后切回转录耗时 **15.531 秒**，触发 5 秒上限断言。观测到应用约占满一个 CPU 核心。
- 最终 UI 用例通过：连续 18 次切换，逐次核对转录标题、聊天输入框、记忆行，最后打开笔记并验证详情控件；点击/等待空闲过程约 **2.09–2.54 秒**。这些数值包含 XCTest 的自动等待，不能当作真实触摸到画面的延迟。
- 两条定向并发测试通过：最终 1,200 条笔记后台准备约 **0.442 秒**，期间主线程心跳 **55 次**；相同资料连续复用 30 次约 **0.033 毫秒**。另覆盖搜索、取消、旧请求不得覆盖新结果。
- 旧 `testMemoryCardDigestAndSectionGroupingExtractsCleanHierarchy` 有三处失败：日志类别文案与正文清理预期已过时。已在恢复的基线实现上复现同样三处失败，本次未调整这些格式行为和预期。

UI 回归使用 `Tests/AgentRuntime/serve_chat_interaction_fixture.py --large-memory`，将其生成的配对清单放入模拟器 App 的 `Documents/momo-simulator-pairing.json`，运行 `MoMoAgentRemoteUITests/ChatInteractionTests/testTabSwitchingWithLargeNotebook`。测试包需正常的模拟器签名，否则钥匙串拒绝写入配对凭据。

定向单元回归位于 `LifeIllustrationJourneyLayoutTests` 的 `testMemoryProjectionKeepsMainActorResponsiveAndReusesCompletedSnapshot` 和 `testCancelledMemoryProjectionCannotReplaceNewerNotebook`。

未在实体 iPhone 安装或验证。本次 Debug 模拟器产物不作为正式发布包。
