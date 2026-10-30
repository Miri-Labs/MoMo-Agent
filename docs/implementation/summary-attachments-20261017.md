# 总结稳定性与聊天附件

基线 `8b811cc`，候选版本 `1.2.0`。按 Ponytail full，沿用归档、Pi 持久会话、SwiftUI 选择器和现有离线消息页面。

## 结果

时间线总结不再在每次整理进度刷新时清空。详情页即使没有先加载日期列表，也会读取缓存；详情中后续生成的总结也能刷新。总结独立成卡片，标题和底色与原文区分。缓存按实际输入段落与来源身份保存，播放可用性、整理状态和无关的转录版本增长不再改变摘要键；正文修订和删除仍使旧总结失效。兼容旧缓存并在读取时迁移。清理缓存与读取缓存使用同一份内容判断。

聊天加号改为照片图库与文件选择。选中的照片或文件先显示在输入框上方，可以移除、点开预览，也可以只发附件。发送后的卡片仍可预览。PDF 提取文本；文本、JSON、代码和 CSV 按 UTF-8 读取。界面不会把提取的文件正文铺到用户气泡里。重试、重新生成、退出后恢复草稿和持久聊天历史都携带原附件。

### Claude 参考

2026-10-17 用 ego-browser 查看 `claude.ai/new` 实际加载的公共 bundle，并用合成文本与图片核对 DOM。没有发送聊天消息；检查后移除测试附件并关闭本轮页面。

- [加号菜单 bundle](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/c752b32f8-L8GXlpPO.js)：`uploadFile` 菜单项与 “Add files or photos” 入口。
- [附件组件 bundle](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-2-vpvuIZgb.js)：`MessageAttachmentsFile`、`MessageAttachmentsImage`、`hz` 移除按钮、`Q$` 图片布局及 `hN` 文件名布局。
- 实测两类卡片均约 120 × 120，圆角 12；文件名最多三行，下面保留简要信息和格式标签；图片使用 `object-contain`。右上角移除按钮视觉尺寸 20，移动端常显。实现按这个组件结构适配 SwiftUI 与消息页面，保留 MoMoAgent 的主题和系统字体；原生移除按钮的点击范围为 44。

源文件、SHA-256、代码位置及合成 DOM 记录放在本轮 `tmp_agent_output/20261017-summary-attachments/claude-bundles/` 和相邻证据文件，不将第三方整包提交到产品仓库。

### 手机开销与边界

每轮最多 4 个附件，选择前的单文件上限 20 MB。照片用 ImageIO 直接生成最长边 1536 的 JPEG，模型图片不超过 1 MB；消息页面只接收最长边 160 的小预览。文件提取文字总量最多 48 KB，PDF 最多 200 页；超限时显示错误，不静默截掉内容。扫描 PDF 没有可提取文字时提示按照片添加页面；本轮没有新增 Office 文档解析器。

导入与压缩在后台执行。草稿的附件内容只写一次，草稿 JSON 仅存引用，移除或成功发送后清理不再引用的草稿文件。显式发送才进入模型请求；图片和文本通过现有三种协议编码。用户仍需选择支持图片的模型，接口拒绝时保留原请求供重试。没有新依赖、后台上传服务或额外模型并发。

## 验证与交付

本轮证据目录：`tmp_agent_output/20261017-summary-attachments/`。
- `package-final.log`：受影响的 Agent 与 Archive 回归 108 项通过。`package-03.log` 另含 3 项新附件契约测试与已有投影身份测试通过的明细。
- `native-confirm.xcresult`：73 项原生回归通过，0 失败、0 跳过，xcresult 的 runtime warnings 为空。包含真实归档的缓存迁移、文字修订失效、刷新不闪空、直接打开详情，以及附件草稿落盘引用、移除后清理、重开、发送失败恢复、附件独立发送和重新生成。
- 三种协议使用正式 Pi 编码器与原生 URLSession，在合成 URLProtocol 终点确认图片和文件文字均进入请求。受控终点主动返回 400，不连接外部模型。此检查验证传输编码，不代表所有配置的模型都支持图片。
- `web-core-final.log`：消息核心规则检查通过。原生 WebKit 回归核对图片已解码、120 × 120 卡片、预览桥接、流式回复时卡片身份不变。只开放本地 JPEG 缩略图所需的 data 图片来源，正文 Markdown 仍禁止 img 与外部图片。
- `visual-final-summary/` 为默认字号的浅色、深色总结截图；`visual-final-attachments/` 为 WebKit 截图。SwiftUI 的 ImageRenderer 不包含滚动区域中的附件条，不能用总结截图证明原生附件选择器已完成视觉验收。
- ego-browser 直接加载本轮消息页面源码，在 393 宽度用合成附件确认图片解码、两类卡片尺寸和没有横向溢出。`browser-qa.json` 和 `attachments-browser-*.png` 保存结果。
- `source-inputs.json` 固定 646 个源码、资源、配置与测试输入；验证后核对没有变化。早期模拟器运行因设备状态变化而中断，最终回归在恢复本轮设备后完整通过，不以中断运行计通过。

独立本地 HTTPS 摘要响应回归未在本轮启动；新缓存行为由实际 Archive 与持久缓存用例覆盖。未验证外部模型的图片理解质量与长时手机耗电。


## 代码链路

`AssistantView` 调用原生选择器，`ChatAttachmentImporter` 在后台准备图片或提取文字。`AssistantModel` 保存草稿与待提交状态；`AssistantPresentationState` 将草稿附件独立存储，仅把引用写入界面状态。用户点击发送后，`PiAgentHost.performSubmit` 校验附件，把图片编码为 Pi image block、文件文字编码为 text block；`AgentSessionPolicy` 与 Pi 的 input entry 保留恢复、重试和重新生成所需的数据。`AgentTranscriptProjection` 保留原用户文字与附件身份，`ChatRenderSnapshot` 只将名称、格式、大小和小预览传给离线 WebKit。点击卡片经受校验的 session ID 与附件 ID 回到原生预览，不从网页获取任意本地路径。

用户最后澄清：可以合并代码并推送 `main`，不要继续编译，暂不安装手机和手表。此前启动的 Release 构建已通过；此后不再启动编译或设备安装。本轮未执行安装包审计，不把构建通过视为真机验收。
