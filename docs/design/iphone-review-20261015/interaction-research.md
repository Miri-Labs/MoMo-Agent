# 对话交互与流式呈现：实测蒸馏

2026-10-15 · 主要使用 393 × 852 移动视口。MoMoAgent 本轮仅修改可评审草稿，没有改动原生 App。

## 先看采用的方向

保留 Codex / ChatGPT 的简约骨架、系统字体、中性白和原有黑色点阵波形。借用 Claude 的段落阅读节奏、安静状态与增量呈现，不把它的品牌衬线字或偏暖底色搬进整套界面。

用户消息靠右，最大宽度约 70%，22px 圆角，内距 10 × 16px；助理正文没有气泡。正文 16/24、段落间隔 16px，标题 18/26、常规至中等字重。新增尾部默认 100ms 短淡入，完整旧段落不重新播放。逐字模糊只放在评审对照；减少动态效果时取消动画。

当前评审入口：[Pen 设计稿](momoagent-iphone-review-v8.pen)。网页演示已按用户要求移除；下文的网页检查保留为历史研究证据。

服务配置的最终交接已收敛为 Cherry Studio 式通用结构：预设只填入地址和协议，服务名称、API 地址、密钥、协议与模型管理共用表单和验证。百炼预设、专属地址页及地域流程已从当前 Pen 删除；研发交接要求清理现有服务商兼容分支。见 [HANDOFF 的配置约定](HANDOFF.md#6-服务和模型配置)。早期草稿中的专属地址方案已撤销。

## 实际操作过什么

| 参考 | 已观察到的行为 | 观察边界与证据 |
| --- | --- | --- |
| [Claude](https://claude.ai/login) | 已登录后跳转 /new；开启临时对话，发送固定测试问题，观察完整回复；第二次发送中向上滚动并停止，部分正文保留，回到底部入口可见 | 实测为登录后的会话界面，不是登录表单。未读取历史聊天，未测试实际重新生成。[停止与滚动记录](references/claude-stop-scroll.json) |
| [ChatGPT](https://chatgpt.com/) | 未登录移动网页，发送测试、点击消息复制菜单、输入多行；测量用户气泡与输入区 | 首次请求进入停止状态后没有得到可读回答，后一次没有进入生成。因此不把真实流速、停止结果或重试记作已验证。[气泡测量](references/chatgpt-bubble-measurements.json)、[输入区测量](references/chatgpt-composer.json) |
| [Notion Agents](https://www.notion.com/product/agents) | 拒绝可选 Cookie，打开移动菜单与 Resources 分组 | 是营销页面的导航，不是 Notion Agent 产品内部对话。[操作记录](references/notion-interaction.json) |
| [x.ai Bot](https://x.ai/bot) | 展开电脑共享相关 FAQ，展开状态有反馈 | Hero 演示的祖先节点为 inert；没有绕过不可交互状态，没有把演示当成真实聊天。[操作记录](references/xai-interaction.json) |
| [Cursor](https://cursor.com/) | 当前会话跳到 /agents；打开模型菜单、搜索 Claude、打开 Add context and tools | 观察到搜索与渐进展开；没有更改模型、连接工具或提交任务。公开首页美术参考另列。[模型菜单](references/cursor-model-picker.txt)、[操作记录](references/cursor-interaction.json) |
| [第三方 Claude Storybook](https://claude-storybook.bystanderss.chatgpt.site/) | Replay、中文/组合 emoji/重音、Thinking 展开、双行输入、减少动态效果仿真 | 是第三方重建；其“100%”宣传未核实。模型按钮未打开真实菜单，减少动态效果时动画仍运行。[字符与动画观察](references/storybook-graphemes.json)、[操作记录](references/storybook-interaction.json) |

## Claude 的视觉：借什么，保留什么

实际会话 body 为 #FCFCFB，变量还包含 #F9F9F7；用户消息约 15/20，输入 15/21，助理实际段落 16/24。英文正文使用 anthropic-serif，中文由字体栈回退。阅读层级主要靠段落、留白与轻量操作，而不是每条助理消息再套一层卡片。[样式测量](references/claude-style.json)、[实际截图](references/claude-chat-mobile.png)

MoMoAgent 继续 #FAFAFA / #F1F1F1 / #252525 和系统字体；导航 16、正文 16、元数据 12–13。保留自己的图标和波形。这里只吸收阅读秩序，不复制 Claude 的品牌。

ChatGPT 实测用户气泡约占可用会话宽度 70%，22px 圆角、10 × 16px 内距。多行输入布局稳定后，textarea 最大 192px，整个表单约 251px；这是网页测量，不要求原生照搬。我们的草稿输入区仍采用既有的一至六行。

## Claude 实际前端 bundle 的关键区别

仅下载页面已经公开加载的前端 JS / CSS；没有保存凭证或私有 API 返回。211 个公开资源的 URL、文件大小和 SHA-256 在 [资源清单](references/claude-bundle-manifest.json)。原始第三方源码只在忽略的临时研究目录，不作为本项目源码交付。以下是本次版本观察，部署后可能变化。

| 模块 | 能核对的事实 | 设计含义 |
| --- | --- | --- |
| [正文流式渲染 shared-10-DMW1MvVo.js](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-10-DMW1MvVo.js) | 默认 stepChars 22、targetLagMs 550、minStepMs 25、maxStepMs 150；跟踪新增文本边界，有 Markdown 增量与已完成块的记忆处理 | 网络分包与文字呈现分开；只平滑新增尾部，不让整篇按固定逐字动画排队。参数是客户端配置，不是网络或模型速度承诺 |
| [样式 shared-styles-BeNNKhZb.css](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-styles-BeNNKhZb.css) | 正文词块淡入 100ms linear；另有 grapheme 90ms、6px blur、30ms 错开样式；有减少动态效果条件 | 不同组件可以使用不同效果；不能看到 grapheme 类就推断所有回答逐字模糊 |
| [文本显现 shared-20-DXcrOeFk.js](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-20-DXcrOeFk.js) | data-revealing 组件有 initial / idle / out 状态、读屏文本与隐藏的视觉分片 | 更像文本切换或状态呈现能力；没有证据证明它就是本次正文渲染路径 |
| [字符工具 shared-2-DGNnxgW-.js](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-2-DGNnxgW-.js) | 包含 Intl.Segmenter grapheme 分段能力及回退 | 组合字符要按用户可见字符处理，避免拆开家庭 emoji、肤色和变音符 |

正文渲染模块还包含 400ms 的 Web Animations 增量淡入分支、动画时间对齐与清理，以及减少动态效果和文本选择保护。bundle 存在多个分支和特性条件；本次未证明哪条动画分支始终启用。实测时没有捕获到正文 data-revealing 分片，不能把第三方 Storybook 当成正文实现的直接证据。

前台 DOM 观察出现过约 22 个字符一批、相邻更新约 100–155ms 的片段，但也有其他大小和间隔。首次完整回复约 13.4 秒只是一次观察，包含页面状态变化，不是吞吐基准。[完整回复观察](references/claude-stream-trace.json)

第二次停止前可见 403 字符，确认停止后保留 434 字符，停止按钮消失并播报 interrupted，说明停止确认期间仍可能收尾少量已到达内容。向上阅读后最终距底部约 714px，“回到底部”仍显示，没有被完成或停止强行拉回最新。没有证据证明期间滚动锚点逐像素不动。[原始记录](references/claude-stop-scroll.json)

## 第三方 Storybook：可看效果，不照抄结论

示例用 Array.from 切分文本，再按索引每片延迟 30ms、90ms 淡入并从 6px 模糊变清晰。它会拆开 ZWJ 家庭 emoji 与组合重音；整篇排队也会让长回答出现不必要的播放滞后。实测减少动态效果时仍有动画。来源与哈希见 [第三方来源清单](references/storybook-source-manifest.json)。

我们的对照演示按 Intl.Segmenter 分段，最多为新增片段错开 150ms，避免整篇排队。默认正文仅短淡入；系统或评审开启减少动态效果后直接更新文字。这个对照是设计提案，不宣称逐像素复刻 Claude。

## 状态设计与历史演示

等待首段可以停止；新增文字只更新尾部，已完成块稳定。停止时显示全部已接收内容，保留用户问题，恢复发送入口。中断会说明未完成；主动重新生成复用原问题，本稿替换当前回答，不重复插入用户消息。原生版本的历史回答分支仍需在实施阶段确认。

接近底部才跟随。向上阅读后，新片段和完成事件不抢滚动；点“回到最新”恢复跟随。生成时可编辑下一条草稿，Enter 不并发启动请求，停止不清空草稿。输入法组合中的 Enter 不误发；Shift+Enter 换行。

固定长回复包含列表、表格、未闭合代码尾部、中文、组合 emoji 与重音字符。代码/表格在自己的区域横向滚动。只在开始、完成、停止或中断播报状态，不逐字打断读屏。

网页演示独立编写，固定文案与模拟分包不代表真实服务速度。Markdown 仅覆盖这些有界示例；不作为通用 Markdown 引擎。204 个场景清单仍是设计预期，不是 204 项测试通过。

## 历史网页草稿检查

浏览器实际跑通：早期停止、保留部分文字与下一条草稿、停止后发送、中断后重新生成且不重复问题、向上阅读脱离跟随、回到最新恢复跟随、系统减少动态效果、输入区六行上限与离开页面清理。首字到达前的取消另用评审控制器同步检查。

长回复检查曾发现单个换行导致列表与表格过早固定；修正后表格三行、列表六项和代码块完整保留，首个完成段落的 DOM 身份保持不变，正文没有横向溢出。组合 emoji 和重音动画分片也逐项观察过。深浅外观和 393px 视口另做视觉检查。具体结果与早期发现保留在 [草稿检查记录](references/prototype-interaction-checks.json)；这些只验证网页演示，不代表原生 App 验收。

## 本轮以现有代码为准（v8）

当前工作树的 `PiAgentHost.swift:443` 要求模型只对实际采用的片段，在对应事实后以“录音1”等简短标签输出 Markdown 链接，完整复制 citationURL。不要列出所有读过的来源，不要另堆参考原文列表。`AgentModels.swift:120` 明确 sources 是校验与失效处理注册表；`SourceLinksView.swift` 校验 session、span、version、generation 后打开原文。

草稿据此移除固定来源行。普通会话不附来源；引用示例在正文中显示录音1，点击打开原文示例。聊天页面和输入框下方也不重复放模型选择器；配置仍在设置中完成。停止后的可见“已停止”去掉，读屏通知保留；连接失败依然明确告知。

## ChatGPT 当前 HTML 与 bundle（v8）

本次直接打开了 [ChatGPT 移动网页](https://chatgpt.com/)，当前浏览器为未登录版本。实际 HTML 的回复操作为 ghost 图标按钮，无可见文字，SVG 20px、点击区域 44px，输入区中没有模型选择器。本稿采用 20px 工具图标与 44px 点击区域，只保留实际需要的复制与重试。没有照搬账号功能或添加分享功能。

检查了 109 个页面公开加载的 JS/CSS 资源，总计 2,415,732 bytes；[资源 URL 与 SHA-256 清单](references/chatgpt-bundle-manifest.json)。原始副本留在忽略的临时目录。`a-CRGYVokb.js` 的回到底部模板使用 icon-only、full radius、secondary 样式；`a-KIR8sEgC.js` 包含会话图标资源表；`application-frame-runtime-modules-BHatBESV.js` 将回到底部与会话滚动锚点关联。没有把私有 API 或会话信息当作公开资源下载。

[本次 HTML 结构与实测样式](references/chatgpt-footer-html-v8.json) 包含空的助理正文和操作栏。未登录测试这次仍没有得到可读回复，因此没有新增真实 GPT 流速结论；HTML 与已加载 bundle 的控件结构能够核对。

[本地 v8 检查](references/inline-footer-v8-checks.json) 已跑通：停止后无模型选择器、无来源尾巴、无可见停止状态，保留读屏通知；工具图标 20px、点击区域 44px；行内引用点击打开原文。Pen 相应页面与评审板已同步。

## 新聊天与左侧抽屉（v8 局部修正）

再次实测 [ChatGPT 移动网页](https://chatgpt.com/)，393 × 852、未登录版本。侧栏从左侧覆盖当前页面，实际宽约 299px；右侧剩余区域显示遮罩下的原页面。点击外侧可关闭，URL 不变。新聊天在抽屉底部，显示为高 52px 的圆角按钮；不是顶部的普通菜单行。[截图](references/chatgpt-sidebar-mobile.png)、[操作与尺寸记录](references/chatgpt-new-chat-flow.json)

点击新聊天后抽屉关闭，回到新聊天首页；原先未发送的测试草稿仍在，因此没有把“清空草稿”或“自动聚焦”记为已验证。这次没有发送消息，也没有验证登录后历史列表。该版本实际主按钮为蓝色；MoMoAgent 延续已经确定的黑白配色，只吸收入口层级与抽屉关系。

已加载 bundle 中，`a-CRGYVokb.js` 可见移动侧栏触发模板，`application-frame-runtime-modules-BHatBESV.js` 可见 `newChatHref` 与延迟加载的 `new-chat-confirmation`，`octane-shell-shared-Bcz3PlRS.js` 包含移动侧栏控制器与新聊天状态重置关联。这些结构不证明每个特性分支在当前会话启用；本次入口位置与关闭方式以上述实际 HTML 和点击结果为准。

当前 `AssistantModel.newConversation()` 在忙碌时不执行；新建会话后切换到它，不删除旧会话，也没有清空输入草稿。Pen 保留这些语义：左侧抽屉替换旧整页菜单，底部新聊天按钮与页头快捷入口指向新讨论；点遮罩返回当前会话。[三步流程板](new-chat-flow.png) 展示无草稿时的首页。此轮仅更新 Pen 与研究记录，未改原生实现。
