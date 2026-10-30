# iPhone 助理消息渲染移植

已接入正式 AssistantView，不是单独的网页原型。前端参照已分析的 Claude bundle 与一次获授权的公开测试：正文增量、工具过程、状态收尾、用户滚动意图、复制和阅读排版。架构边界见 [ADR](../adr/chat-rendering-boundary.md)。没有复制 Claude 服务端 prompt，也没有打包其生产脚本、账号上下文或专用字体。

## 实现

- MoMoAgent 暴露有序文本、思考与工具内容，保留真实调用 ID、结果和中断原因。工具专用消息不再被过滤，live→durable 使用同一身份，重复交接不增加一条消息。
- 唯一的展示适配器是 ChatRenderSnapshot。独立渲染器没有 Agent SDK、凭据或档案依赖，不能调用模型或工具；原生 AssistantModel 继续拥有命令与订阅。
- Markdown 完成块缓存并复用 DOM，只更新增长中的尾部；处理未闭合格式与后置引用定义。按 grapheme 推进，支持中文、组合字符与家庭 emoji。历史恢复不重播动画，停止时保留真实收到的全部内容。
- 工具组、单项详情、失败和中断有独立展示状态；完成默认收起，用户展开选择保留。正文、代码可复制，来源链接仍由原生版本与权限规则校验。
- 表格横向滚动，代码高亮，公式离线排版；16px/24px 阅读基线，支持深色、大字体与减少动态效果。用户上滑解除跟随，底部按钮恢复跟随。
- AgentInstructions 单独增加私人助理交流方式，减少固定报告模板和工具播报；原有资料、时间、取消、删除屏障和计划幂等规则保留。未调用付费模型对语气做新一轮语义评测。

## 验证结果

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Agent 包测试 | 35 通过，1 跳过 | 新增投影/交接/失败/停止/脱敏，以及真实 Pi + 脚本 provider 回归；百炼付费测试未启用 |
| JS 核心 | 9 通过 | Unicode、修订、分块、引用、工具汇总、滚动和相邻文本块精确保留 |
| iPhone build06 | 24 通过 | 20 项宿主测试 + 4 项原生导航/输入框 UI 测试；早于相邻文本块合并修正 |
| 当前渲染 build08 | 3 通过 | 最新生产资源在真实 WKWebView 中的 Markdown/工具/桥接、滚动/停止、流式 DOM/复制；重新核对截图非空及绘制时机 |
| Release 构建 | 成功 | iPhone 与嵌入 Watch 的模拟器 Release 构建 |
| Release 检查 | 19/19 通过 | 现有检查器：模型哈希、测试入口排除、隐私/后台声明、两端包身份等 |
| 渲染资源 | 37 文件一致 | Release 与源码 SHA-256 逐项相同；32 项固定 vendor 资源校验通过；Watch 不含渲染器资源 |

早期失败日志保留：build01 的命令选项错误、首轮 Swift API 标签/fixture ID 编译问题、公式扩展配置丢失，以及程序滚动与用户快速上滑的竞态，均有后续修复和新结果。首次图像采集的空白帧通过让测试窗口成为 key window、等待字体和绘制完成解决；新增像素差异检查，不能把空白图当视觉证据。

截图为真实 iPhone 模拟器中的正式本地 WKWebView 组件，内容是测试数据，不是真实用户资料或新的模型回答：

- [浅色消息阅读](evidence/2026-10-15-chat-renderer/light.png)
- [深色与大字体](evidence/2026-10-15-chat-renderer/dark-large-type.png)
- [流式结束后的正文](evidence/2026-10-15-chat-renderer/streaming-completed.png)

[证据索引](evidence/2026-10-15-chat-renderer/evidence-index.json) 保存原始结果位置、大小和 SHA-256。xcresult 和完整日志位于本机忽略目录 `tmp_agent_output/chat-port-20261015`。本次不包含真机、Watch 录音/连接验收或整体 v0.1 完成结论。
