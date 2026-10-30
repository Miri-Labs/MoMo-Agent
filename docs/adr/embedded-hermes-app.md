# 将 Hermes 作为 MoMo Agent 内置执行组件

2026-10-21。状态：已接受，开始实施。

用户决定：MoMo Agent 是独立的新 App，将 Hermes 源码 fork 一份放进本仓库，
借用其执行能力并由我们负责完整产品。此决定更新此前“只接外部 Hermes、尽量不
fork”的实现路线。

## 源码和发布所有权

- 完整源码快照纳入 `Vendor/HermesAgent/`，固定在已做主线 POC 的
  `cf4f3a7396814ffcaef69d9af09f7cfdade3ddbe`。不是 submodule，也不依赖用户
  另行安装 Hermes Desktop。上游版本、tree、锁文件指纹见旁边的 UPSTREAM JSON。
- 初始导入不修改上游。MoMo 产品装配、配置、身份、资料同步和客户端放在我们自己
  的目录中；必要的内核补丁可以在这份源码上修改，逐项记录理由和上游基线。
- 整体应用由 MoMo 发布。运行目录与个人 Hermes 安装隔离；不在产品入口暴露
  上游自更新命令，不让 `hermes update` 替换 MoMo 的代码。上游更新通过任务分支
  导入、审查差异并回归，再随 MoMo 发布。
- 保留 MIT 和嵌套版权／许可证；对外品牌和界面属于 MoMo。原始源码里的名字无需
  全量替换，避免无意义差异与升级困难。

## 职责边界

手机继续采集、ASR、离线回看、前端渲染与持久同步；删除手机 Pi Agent，不提供本地执行或故障回退。
Mac 运行内置 Hermes，负责唯一的模型／工具循环、原生记忆和会话。MoMo 保留资料、修订与多端同步，
不另建事实记忆库。客户端使用明确的任务接口，Mac 端 MCP 提供资料。
网络连接仍独立处理。

这次从最底层接通：可追溯源码导入、独立运行目录、受控启动和实际 runs 接口。
手机迁移、资料／记忆权威库、产品 Mac 界面、后台服务安装与签名分发后续依序接入。
同日用户进一步明确只保留远程 Mac 方案，覆盖先保留 Pi 的过渡安排。
手机不包含 Pi 依赖或本地 Agent。Mac 不可用时保留待发送内容；已有远程任务按原 ID 恢复，不在手机接管执行。
当前迁移不等于产品 Mac 界面、常驻服务和签名分发已完成。

## 检查点

导入后的 Git tree 与上游完全相同，包含内容与文件模式；运行必须从本仓库的 Vendor 路径加载。
首次启动需明确模型配置；默认只监听 loopback 并要求 bearer 凭证。
任务接收后由 Gateway 持有生命周期，客户端退出不发送 stop；恢复读取实际快照，
使用同一幂等键重试，unknown 不自动重跑。

基础接入见 `docs/implementation/hermes-foundation-20261021.md`；最新远程主线、Dots 交互、验证与未交付项见 `docs/implementation/hermes-remote-mainline-20261021.md`。

## 录音与记忆的实现边界

手机 Archive 是录音原文权威库；带 library/session/device 身份、generation/version、片段时间及全文 SHA-256 同步到 Mac。Mac 只确认事务提交后的回执。引用中的版本固定，修订或删除后旧依据失效；删除墓碑不能被迟到重试复活。

Mac 的 MoMo context SQLite 保存资料副本、同步版本和已投递段落的哈希，不复制手机 SQLite。Hermes 通过 MoMo MCP 按需分页读取原文。自动整理使用同一个 Hermes home 的受限 run，只开放来源读取和原生 memory，不开放终端、文件写入、发送和技能维护。待办是建议，当前用户任务才授权执行。原生记忆、输入频次和健康资料方案见 [最新简化实现](../implementation/hermes-native-memory-20261021.md)。

任务与记忆任务的 POST 接收回执、GET 执行快照分别建模：先持久保存 run_id，再读取快照；丢失回执只在幂等保留期内使用同一 operation ID 重放。应用退后台只解除观察，不发送 stop；明确停止由用户操作发起并等待状态确认。

手机缓存 Hermes 当前记忆列表；删除直接修改原生条目，需要 Mac 在线，失败保留原视图。原始转录和聊天记录独立保留。原生 Markdown 不提供结构化证据级撤销，因此不承诺删除来源会自动撤回所有相关记忆，也不承诺语义永久遗忘。旧 MoMo 事实表和待同步编辑仅保留，不自动迁入或应用到 Hermes。

本阶段 Mac 通过开发运行入口提供 Gateway 与资料服务，默认只监听 loopback；异地连接由独立的 HTTPS/VPN 网络层暴露两个端点。MCP 是 Mac 的资料工具接口，不承担手机网络穿透。
