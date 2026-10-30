# Mac 远程执行主线与 Dots 交互

版本：1.19.0。基于 main `2148b691` 开发，内置 Hermes 基线 `cf4f3a7396814ffcaef69d9af09f7cfdade3ddbe`。

> 本文保留 1.19.0 主线验收记录。后续 1.20.0 已加入 Mac 客户端与自动临时入口；1.21.0 按用户要求改为 Hermes 原生记忆。下文旧 momo-memory profile、MoMo 事实表与离线遗忘机制已退出当前路径，现状以 [原生记忆与手机资料](hermes-native-memory-20261021.md) 为准。

## 当前实现

手机移除 MoMoAgent、PiDurableKit、Pi 执行入口、旧模型配置、Dream 与本地 Agent 后台任务。保留录音接收、ASR、时间线、原文、回放和渲染器。仅连接 MoMo 自己管理的 Mac Hermes 实例；不提供手机执行或本地故障回退。

`PhoneRemoteAgent` 管理连接和 Keychain 凭据；`RemoteTaskStore` 在发送前持久化用户输入、operation ID 和会话。POST 的小回执与 GET 的完整快照分开处理：先保存 run ID，再核对会话和结果。丢失回执仅在已确认的持久幂等窗口内重试同一提交；已有 run ID 永不重新提交。退后台仅取消观察，明确停止通过停止接口提交并查询确认。

手机将 Archive 中完整转录封装为来源版本，先落盘再上传。Mac context SQLite 保存副本、校验和、来源修订和删除墓碑。MCP 分页读取原文并要求固定版本、明确游标，不静默截断。Hermes 的受限 momo-memory profile 整理事实和建议，工具范围仅包含来源与记忆；不会因录音中的待办自动执行。

记忆由 Mac 单写，有明确陈述/推断、录音时间、精确引用和来源版本。原文修订使旧依据失效；删除来源撤销对应证据；忘记操作持久化且幂等，并暂停相关来源的自动提取以避免马上再生。录音原文仍在独立转录页面，记忆页不代替原文与播放器。

## Dots 参考与实现

只读查看本机 ChatGPT.app 26.1013.40934 的 Dots bundle：`composer-controls-db9f3c1ee1ee.js` 和 `app-initial-e7c27dd40beb.css`。参考结构与尺寸，使用自有 SwiftUI/HTML/CSS 实现，不引入对方私有 API 或产品资源。

- 用户消息靠右，小圆角气泡；助手正文铺开，无大面积底色。
- 等待气泡宽 56、高 40；三个 8 点圆点、4 点间隔、1 秒明暗周期和错开相位；进入约 180 ms。减少动态效果时静止，页面后台暂停。
- 首字或完整中途回复到达即结束等待；任务状态独立显示，停止/核对收进任务操作菜单。
- 保留 MoMo、手表状态小标与浮层、聊天/转录双 Tab、独立记忆页。
- Mac 提示契约要求先简短回复理解与下一步，再调用工具。手机不生成假的确认句。真实模型遵从度需要另行验收。

使用 Hermes SSE `message.delta` / `message.interim`；将真实中途回复和序号持久化，恢复使用 Last-Event-ID。完整 interim 替换相应 delta，不重复显示；不呈现 reasoning 事件。事件回放过期/重启后不可用时提示过程缺失，仍通过 run 快照核对结果，不重新执行。

实际测试发现 Hermes canonical admission 路径遗漏 interim 回调，已在 fork 中增加回调转发；直接路径和 canonical 路径现在使用同一事件契约。补丁登记在 `Vendor/HermesAgent.UPSTREAM.json`。另修复 WebKit 首次显示等待隐藏视图 animation frame 的互相等待；DOM 渲染成功后直接显示，原生首次绘制也保留相同三点等待。

## 验证

- Swift transport/store/SSE：18 项通过。
- Python runtime/context：13 项通过。
- `MoMoAgentRemote` 模拟器端到端：1 项通过、0 跳过；实际嵌入 Hermes、真实 MCP 和 HTTP，模型为可控合成 fixture。
- 事件证据：`run_a7bec5becac24585a621b7a44f5a5f54` 的 `message.interim` 序号 0，第一次 `tool.started` 序号 1，最终 completed。手机退出之后才写结果文件，重开仍为相同 run ID，先前回复与草稿保留。
- 回归首轮 50 项中 48 项通过；MoMo 名字的可访问性标识补回后，对应手表状态 UI 用例通过。动效用例改为等待实际使用时的品牌动画初始化，并改截三点等待区域后通过；不是将失败项跳过。覆盖录音接收、后台 ASR 生命周期、原文阅读、首次渲染、三点等待、减少动态效果与后台暂停。
- Release 模拟器构建通过；手机、内嵌 Watch 和 Widget 均为 1.19.0，共享构建版本一致。包审计检查模型校验和、Debug 测试入口缺席、两条转录后台任务声明，全部通过。未安装到真实手机。
- 19 项渲染核心 JavaScript 检查和聊天四语言检查通过；原生与编译后字符串覆盖检查通过。
- Dots 比对与模拟器截图对应本次 UI，不声称完整复刻 Dots 全部功能。

## 尚未交付

本轮无真实手机、Watch 或真实异地网络测试。Mac 开发入口绑定 loopback；实际异地须经既定 HTTPS/隧道配置并独立验收。合成模型证明链路与顺序，不证明模型理解质量。

旧 Pi 历史/记忆只读迁移、手机健康/日历/邮件等能力桥接、附件远程传递、Mac 正式客户端与签名安装、手机结果文件下载仍待后续实现。旧用户文件未删除；当前新客户端不展示旧 Pi 历史。旧 Pi UI 测试随对应入口退役，保留录音/播放/手表状态/储存空间测试，并迁移导航入口。
