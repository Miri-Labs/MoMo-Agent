# 状态、存储与长对话修复

基线 `cb813bb`，共享配置版本 **1.3.4**。在 Linux 云环境实施；没有 Xcode、Apple SDK 或连接的用户设备。

## 录音状态与存储

- 手表分别展示本机录音和同步等待，避免把等待连接理解为停止录制。
- 手机过期、恢复的状态显示“上次报告”的实际状态、更新时间与待更新说明。实时绿色和动画仍要求新鲜报告及近期采样，不延长可信时间窗。
- 前台对账、连接可达时可请求对端重新观察状态；即时请求最多每 5 秒一次，不进入持久指令队列，响应不会循环触发请求。
- 手表每次实际发布心跳都刷新源时间和 revision，即使暂停／空闲 payload 未变。旧报告重放不刷新手机端新鲜度。
- 新录音从 32 kbps AAC 调为 24 kbps，保持 16 kHz、单声道和完整采样边界。按目标码率约 10.8 MB／小时，目标音频占用减少 25%；实际大小受编码器和容器影响。
- 不重编码或替换已有音频，不改变已保存的保留期限、上限和受保护音频规则。
- 持续处理中新转录完成也触发合并的有界清理，不再只依赖完整刷新或处理进入空闲。
- 储存页说明压缩格式，以及未完成转写、确认或仍在使用的原音可能暂时超过规则。模型、正文和索引仍分别统计。

## 长对话只回复一个字

确认的代码缺陷：Pi AI 1.2.0 的 `clampMaxTokensToContext` 从上下文估算再扣 4096 安全余量，将输出预算下限设为 **1**；应用同时关闭了自动 compaction。历史／工具结果增加后，合法配置的输出预算可被静默降成一个 token，与用户反馈的短残片现象吻合。

- 复用 Pi 的持久压缩。阈值按当前连接的上下文窗口和输出上限设置，预留至少完整输出预算，保留近期原文。只在活动请求内压缩，遵循来源校验、隐私、次数和取消边界。
- 带原始 SHA-256 校验、可重复应用的 SDK 补丁保留调用者的输出预算。真实超限走显式错误与压缩恢复，不以极短输出伪装完成。
- 错误解析仅增加已知上下文超限 code 的闭集分类；向 Pi 提供固定可识别错误，原错误正文和凭据不持久化、不展示。
- 压缩请求补齐独立的 durable transport identity，沿用有界传输和取消。撤销权限后的旧上下文不发送给摘要模型。
- 聊天记录从持久日志分页补齐，并按压缩边界缓存。压缩只缩短模型活动上下文，旧消息仍可阅读、重启恢复与重新生成；摘要不会成为用户聊天气泡。

## 前端反馈与参考

`AgentSnapshot` 传递真实 compacting、compacted、failed 状态。消息区域复用原品牌动效显示整理提示，完成后继续回复，正文输出时让位。失败停止动效并说明记录保留，使用已有重试入口。取消和新会话清除活动提示，状态变化通过现有 polite live region 播报；不显示估算百分比。

参考资源均为公开访问，没有登录、读取其他账户的对话或把第三方 bundle 复制入库：

- [Codex compaction 源码](https://github.com/openai/codex/blob/main/codex-rs/core/src/compact.rs)：压缩较早内容并构造可继续工作的 checkpoint。
- [Claude Code 上下文说明](https://code.claude.com/docs/en/how-claude-code-works#when-context-fills-up)：接近上限时管理较早工具输出并总结会话，持久规则独立管理。
- [Claude 会话 bundle](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-1-DwP4SkAi.js)：`onCompactionStatus` 分别保存 compacting、complete、failed；失败有恢复动作。
- [Claude 状态组件 bundle](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-17-DjawkfW4.js)：独立压缩提示、完成过渡和普通等待状态区分。本项目采用状态区分，不复制其代码或估算进度行为。
- 也读取了 ChatGPT 公开入口及其直接引用的部分 CDN bundle，未在所读资源中验证到对应压缩提示，不将其内部实现当成已确认结论。

公开 bundle URL 是读取时的资源标识，后续可能变更。生成的 SDK bundle SHA-256：`aa14967b4f02da9720a03b218eed339569151e6e2305c1dc9c0f9df247d592cd`。

## 验证与边界

已执行：

- `Vendor/PiDurableKit/JS` 的 `npm test` **47/47**：包含真实本机 HTTP 编码器下长上下文完整输出预算、分段流式正文完整性、超限错误脱敏、主动／超限压缩恢复、原请求身份与原历史保留。没有请求外部模型。
- `npm run build`：TypeScript 类型检查、受校验补丁与 JSC bundle 重建通过。
- `node Tests/Support/chat-renderer-core.test.cjs` **19/19**，包含压缩、完成后输出、失败和取消后的状态。
- `Tests/Support/chat-renderer-compaction.py` 通过：Chromium 加载生产 renderer，验证压缩／完成提示、完整输出、原消息 DOM 保留、失败停止动效、取消及辅助功能播报。390×720、默认字号，实际查看压缩中截图。
- 变更 Swift 源码经 tree-sitter 与基线对照，无新增语法解析发现。此项不等同于 Swift 类型检查或 Apple 构建。
- 源码空白检查通过；生成 bundle 的模板字符串行尾空白沿用上游形式，不手改字符串消除提示。

新增／更新但本环境未执行的 Apple 回归：过期状态显示、刷新不变 payload 的源 revision、AAC 完整分钟占用和采样边界、按模型设置压缩阈值、隐私撤销、完整聊天／重启／重新生成、原生 WebKit 压缩状态。

**仍需 Apple 环境验证：** iPhone／Watch 编译与原生测试、实际 App 包版本审计、AAC 真机听感及转写质量、后台状态传播、全天录音与功耗。本轮未生成或安装新 App，1.3.4 是源码共享配置版本。

重跑浏览器验证（浏览器放任务临时目录）：

```sh
PLAYWRIGHT_BROWSERS_PATH=/tmp/momo-playwright uv run --with playwright==1.62.0 python -m playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/tmp/momo-playwright uv run Tests/Support/chat-renderer-compaction.py
```
