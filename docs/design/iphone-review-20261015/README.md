# MoMoAgent iPhone 交互草稿

本轮设计以 Pen 为唯一评审入口。HTML 预览、运行脚本与生成用中间文件已移除，原生 App 代码没有改动。Pen 已安装并登录；Impeccable、Taste 与四个 iOS 设计技能已下载。

- [研发交接文档](HANDOFF.md)：逐页引用当前 Pen 节点，包含最终交互、视觉规格、代码缺口和验收要求。
- [当前可编辑 Pen 稿](momoagent-iphone-review-v8.pen)：29 个代表页面，播放器补充已获用户确认，纳入本轮实施。
- [全部场景](cases.md)：220 个预期场景，15 类；不是测试通过报告。
- [原音播放器放置与交互](AUDIO_PLAYER.md)：Pen `mxQKw`；详情主播放器、列表迷你条与原文片段，附 [三屏预览](audio-player-placement.png)。
- [交互研究记录](interaction-research.md)：参考网站、公开前端资源与现有代码的核对结果。
- [本轮行内引用与聊天界面](chat-inline-v8.png)。
- [新聊天开启流程](new-chat-flow.png)：当前会话 → 左侧抽屉 → 新聊天。

## 已采纳的反馈

保留原有聊天首页、侧栏和黑色点阵波形。底色改为中性浅白 `#FAFAFA`，表面 `#F1F1F1`；原始品牌图标保持原图颜色，回到首页、首次使用与侧栏。Apple Watch 使用方圆表壳轮廓，原生实施继续采用已有 `applewatch` 系统符号；Pen 的设备轮廓是可编辑代理。

侧栏字体收轻为品牌 16、菜单 15、最近会话 14、分组 12，常规字重。移除重复副文案与图标底框，行命中区域仍为 44。

侧栏改为覆盖当前会话的左侧抽屉，不再是带返回键的整页菜单。底部主按钮开启新聊天；点击右侧遮罩回到原会话。当前会话在历史中保留，未发送草稿沿用现有代码的保留规则；主页右上角同步为新聊天快捷入口。流程板展示无草稿时的新聊天首页。

移除独立计划页及其入口。本机转写自动进行，没有就绪开关、暂停操作或转写模型管理。等待、处理中、失败只在受影响录音旁说明。

首次不预选服务商或模型。提供 DeepSeek、Kimi、智谱、硅基流动的地址预设和自定义入口，统一使用名称、API 地址、密钥、协议和模型配置。百炼预设与专属地址页已删除，不设地域、服务商专属开关或兼容分支。参考 Cherry Studio 的通用结构，预设只负责填值；读取或手填模型 ID 后独立验证，新配置成功前保留旧连接。

## 预设与外部参考

`provider-presets.json` 是设计提案数据，不是已接入的原生配置。只显示现有代码支持的三个协议族：Chat Completions、Responses、Anthropic Messages。不同协议的基础地址仍需按服务文档设置。目录不可用时可手填 ID；目录读取成功不等于模型调用权限通过。

| 服务 | 预设基础地址 | 官方依据 |
| --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | [模型与服务地址](https://api-docs.deepseek.com/quick_start/pricing/) |
| Kimi | `https://api.moonshot.cn/v1` | [API 概述](https://platform.kimi.com/docs/api/overview) |
| 智谱 | `https://open.bigmodel.cn/api/paas/v4` | [通用 API 快速开始](https://docs.bigmodel.cn/cn/api/introduction) |
| 硅基流动 | `https://api.siliconflow.cn/v1` | [快速开始](https://api-docs.siliconflow.cn/docs/userguide/quickstart) |

配置结构参考 [Chatbox](https://docs.chatboxai.app/en/guides/providers) 的服务协议、密钥、地址与模型分层，以及 [Cherry Studio](https://www.cherryai.com/docs/en/pre-basic/settings/providers/) 的官方 Host 预填、模型同步与模型检查。不是把桌面设置页直接移植到 iPhone。参考核对日期：2026-10-15；实际模型目录与账号权限需在实施时读取。

## 评审方式

直接在 Pen 打开 `momoagent-iphone-review-v8.pen`，查看页面与状态板。设计源文件通过 Pen MCP 或编辑器维护。图片、场景清单和研究记录用于辅助查阅；不再启动网页预览服务。

Pen 中中文使用 Noto Sans SC 代理；原生实现继续使用系统字体与 Dynamic Type。草稿不等于 iPhone/Watch 原生实现或 E2E 验收。

## 本轮流式提案

正文 16/24、段落间距 16px，用户气泡最大约 70%、22px 圆角，助理不套气泡。聊天页不重复选择模型，模型配置统一在设置管理。默认新增尾部 100ms 短淡入；逐字模糊只作评审对照。停止保留已接收内容；向上阅读解除跟随，点击回到最新后恢复。组合字符按 Intl.Segmenter 分段，系统减少动态效果时取消动画。

参考网站实测包含两次 Claude 临时测试回复；不读取用户历史。ChatGPT 未登录会话没有获得可读的真实回复，因此没有把它的流速和停止结果记作验证。公开 bundle 原始副本仅存于忽略的临时目录，交付 URL 与哈希清单；已移除的网页演示曾采用独立编写的固定示例。

历史网页草稿检查见 `references/prototype-interaction-checks.json`。修正分包落在单个换行时过早固定 Markdown 块的问题后，长回复中的表格、六个列表项与代码块均完整呈现。

本轮局部修正：回到底部改为水平居中的圆形向下箭头；复制与重试使用 20px 灰色图标、44px 命中区域，沿正文左边缘对齐。移除固定来源行，引用由模型在对应事实后以内联 Markdown 链接生成。普通停止不再重复显示文字状态，保留读屏通知。

当前代码核对：`PiAgentHost.swift:443` 明确要求只引用本次实际采用的片段，不额外堆来源列表；`AgentModels.swift:120` 的 sources 是校验注册表；`SourceLinksView.swift` 负责解析链接并打开原文。当前代码已改为此方式，本轮没有改动原生实现。

复制按钮局部修正：以已采集的 ChatGPT 复制图形替换旧代理，统一 20px 图框内的纸张重叠比例与轮廓，44px 点击区域保留；已同步当前 Pen 中的五处副本。
