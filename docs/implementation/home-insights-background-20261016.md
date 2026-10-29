# 首页建议与后台时间线整理

## 设计依据与交互

采用 [Pen 设计稿](../design/iphone-review-20261015/momoagent-home-suggestions.pen) 的 H01（节点 `GiJ7x`）；尺寸、颜色和原创点阵见[设计评审](../design/home-suggestions-20261016/DESIGN-REVIEW.md)。输入框下最多两张卡片，采用局部雾紫、浅鼠尾草绿。页面、顶部品牌、中央 Avatar 和原有波形保持既有系统。卡片纹样静止；没有可用建议时保留原有留白。

用户补充确认：**点击卡片，立即给 Agent 发送可见消息，并开始原有流式回复。** 标题明确起草、梳理或比较的主题，相关来源随消息传入；不再等待第二次点击发送。发送走现有 AssistantModel/PiAgentHost 链路，包括失败恢复、停止、引用和会话持久化。键盘聚焦或存在草稿时隐藏卡片；发送前再核对来源与草稿，保留用户后来输入的内容。

长按可查看依据、暂时收起、反馈不准确。发送后的建议也会收起，避免返回首页时重复出现。收起保存为本地反馈，有效七天，不删除录音，也不写 USER/MEMORY。反馈不准确进入用户可编辑的纠正消息；是否更新记忆沿用 Agent 当前能力及用户指令。

## 运行与缓存

- PhoneRuntime 持有 PhoneInsightsModel 和 AutomaticInsights；页面只读摘要缓存，打开时间线可请求补齐对应日期。任务不随页面离开而取消。
- ArchiveStore 提供元数据目录，覆盖所有未删除录音涉及的当地日期，包括跨午夜和晚到的历史录音。转录、录音关闭、活动分组、删除或修订改变目录版本。
- 待处理日期、建议刷新意图、请求次数及重试时间先写入磁盘，再发请求。历史日期逐一整理，已完成且版本匹配的摘要直接复用。进程中断后重建运行时可恢复待办。
- 两类工作均只使用用户保存并激活的模型连接和凭据，复用项目现有 OpenAI Completions、Responses、Anthropic 协议配置；没有平台、品牌或地域专用分支。未配置模型不发自动请求。
- 建议结合 USER/MEMORY 与最近三天内已完整转写的资料，最多八个时间窗口、12 KB 转录，并受所选模型上下文预算约束。没有合适依据时允许零条。生成请求没有工具，不自动写记忆或操作外部应用。
- 建议最短生成间隔十五分钟，缓存有效六小时；新资料、用户记忆或模型变化触发刷新。生成失败保留仍有效的缓存，不阻断输入，也不展示首页加载骨架。
- 每条建议保留真实资料引用，模型只返回受约束的动作、主题、短说明及证据编号。程序校验条数、长度、重复和证据范围。点击时重新核对缓存；资料修订、删除、记忆或模型变更后不发送旧建议。
- 单次自动模型调用最长六十秒、一次 HTTP 尝试。请求准入次数持久化，失败或中断依次退避一分钟、五分钟、三十分钟、两小时、一天；第五次后等一天才开始下一轮。新录音不会清空原失败任务的退避。

## iOS 后台边界

前台开始的整理取得有限的 UIKit 后台执行时间；到期取消当前工作，保留待办。另注册网络可用的 BGProcessingTask，系统给予机会时恢复整理，并在到期或完成时结束一次系统任务。注册标识同时写入 project.yml 和 Info.plist。

这允许离开页面后继续、短暂切后台继续，以及系统调度后的恢复；**不是常驻进程，也不保证固定时间唤醒**。强制退出后仍受 iOS 调度规则约束。现有本地 ASR 的后台门禁保持不变，本次后台能力针对已转写资料的模型整理。

依据：[UIKit 后台执行时间](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)、[系统后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)、[网络条件](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresnetworkconnectivity)。

## 验证

- 合并最新 main 后，MoMoAgentTests 共 100 项通过，包含本次新增的 10 项自动整理测试：无模型时不请求、来源修订与删除、记忆变化、格式与证据校验、跨午夜目录、历史日期整理、缓存去重、持久化恢复和退避。
- 原生 Debug 测试构建通过。六项集成检查覆盖卡片直接发送及资料引用、保留草稿、损坏可选缓存不阻断启动、后台到期前/到期中/正常完成只确认一次；两项 UI 流程覆盖卡片点击、输入焦点、收起卡片、抽屉与新聊天。
- 受控传输账本确认一次卡片点击只有一次请求，收到 200 和流式正文分片，停止后记录取消。使用真实 App、Pi、URLSession 与聊天渲染器，回复和资料均为隔离的合成内容；没有付费模型请求。
- Avatar 原有程序轮廓与轻微动画保持不变。原生检查从尚无布局锚点到可见位置，验证 WebKit 加载、真实像素绘制与可见尺寸；UI 截图等待 Avatar 实际绘制后采集，避免把首帧前的空白当作最终效果。仅按系统默认字号验证。
- 已使用 XcodeGen 2.46.0 生成工程，并保留 main 的 Watch scheme。本次未把真实模型回答质量、系统实际唤醒时间或真机后台续跑记作已验证能力。

本地可复查证据位于本任务 worktree 的 `tmp_agent_output/insights/`：`native-final.xcresult`、`visual-final.xcresult`、`final-home.png`、`final-reply.png` 和 `final-stream-ledger.json`；依赖与生成的测试文件未提交。
