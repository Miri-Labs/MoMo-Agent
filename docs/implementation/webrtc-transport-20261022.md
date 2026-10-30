# WebRTC 数据通道：1.23.0

在 `codex/hermes-app-20261021` 增加手机与 Mac 的 WebRTC 数据通道。现有配对、Hermes 任务 API、operation/run ID、SSE 事件游标与停止语义保持单一归属。

- 已鉴权 HTTPS 交换 SDP、ICE 配置和稳定执行身份；只接受已配对设备。DataChannel 会话绑定这次协商、设备凭据和服务端身份，不开放任意端口转发。
- 网络适配器只承载白名单请求及响应字节，不创建 Agent、不保存另一份任务、不从模型正文推断完成。
- HTTPS 在协商期间继续可用；WebRTC 建立并核对身份后用于小型请求和事件。大资料继续 HTTP。已发送但结果不明的写请求不会因换路立即重发，交给原有幂等与状态核对恢复。
- 事件按原游标续读；取消网络观察只关闭订阅，不发送远端 stop。旧连接迟到的回调不得关闭新连接。
- 信令通过既有入口，STUN/TURN 接受标准可替换配置。没有中继时不承诺所有 NAT 均可直连，保留 HTTPS 回退。
- 手机后台不维持长连接。关闭连接后 Mac 执行继续，前台重新协商或使用 HTTPS 恢复。

参考 OpenUUYC 的连接生命周期与业务会话分离、Oki 的稳定身份与多路径思路；实现使用独立的 WebRTC 库，不复制其私有协议或专有业务源码。本轮仅数据传输，不增加屏幕或键鼠控制。

## 代码边界

`MoMoAgentClient/AgentTransport.swift` 定义响应字节接口，Foundation 客户端继续解析原 JSON/SSE。可选的 `MoMoAgentRTC` 只处理 HTTPS 信令、ICE、DTLS/SCTP、请求复用和连接状态。手机任务日志继续由 `RemoteTaskStore` 持有；配对身份和密钥继续由原配对与钥匙串流程管理。

Mac 的 `Access/rtc_transport.py` 与 HTTPS 接入共用路由白名单，向原本的本机 Agent/资料 API 转发。它不导入 Hermes，不调用模型供应商。根管理密钥不发送到手机，设备凭据不向本机 Agent 透传。关闭订阅或连接不会调用任务 stop。

数据帧上限 32 KiB，响应分片 12,000 字节，单个普通响应上限 8 MiB。事件流按字节持续读取；缓冲溢出或超限显式报错，不截取后冒充完整结果。大请求在发送前选择 HTTPS。写请求一旦交给 RTC，连接错误只向任务层报告，由原 operation ID 恢复；不在传输层立即重放。并发上限每连接 16 请求、每设备 2 连接、服务共 16 连接。

首次加载 Python 原生依赖在线程中进行，最多等待 10 秒，避免阻塞 HTTPS。原生 ICE 完整收集若被某个不可达接口拖住，8 秒后使用已经收集的有效候选；relay 策略只接受已收集的 relay 候选。协商总时限 25 秒，失败冷却 30 秒，期间请求继续走 HTTPS。关闭旧 peer 前先清除其标识，迟到回调不会影响新连接。

## 可替换的入口和 ICE

现有临时 tunnel 与自备 HTTPS 入口继续用于信令和回退。WebRTC 不依赖 tunnel 供应商 SDK；ICE 使用标准 `stun:` / `stuns:` / `turn:` / `turns:` URL、username、credential。Mac 本机管理 API `POST /webrtc/configure` 接受：

```json
{
  "enabled": true,
  "ice_transport_policy": "all",
  "ice_servers": [
    {"urls": ["stun:stun.example:3478"]},
    {"urls": ["turns:relay.example:443?transport=tcp"], "username": "device-user", "credential": "issued-secret"}
  ]
}
```

该接口位于 connection.json 的 port + 3，仅监听 loopback，需要 Mac 根密钥。配置私密保存为 `access/webrtc.json`（0600），重配关闭网络连接、保留设备授权与运行任务。手机从已鉴权的 `/transport/v1/config` 获取 ICE 参数。撤销设备立即关闭对应 peer，并在每次转发/发送时复查授权。`ice_transport_policy: "relay"` 可强制手机走中继。

默认启用 WebRTC、ICE 列表为空，适用于可达的 host 候选；未配置公网中继时继续保留 HTTPS 可达性。没有内置商业 TURN 凭据、生产 relay 服务或租户专有协议。使用短期凭据的 TURN 服务可通过同一个管理接口更新，无需替换客户端。

依赖分开锁定：Apple 使用 stasel/WebRTC 155.0.0，Mac 接入使用 aiortc 1.15.0。Access requirements.lock 的既有包版本约束来自 Hermes uv.lock；安装核对哈希及 `uv pip check`，依赖指纹升级不重置身份、资料或任务记录。重开 Mac App 时自动准备接入依赖。

锁文件重建：先使用 `uv export --project Vendor/HermesAgent --frozen --extra mcp --extra messaging --no-dev --no-emit-project --no-hashes --format requirements-txt -o hermes-constraints.txt` 导出临时约束，再运行 `uv pip compile Apps/MacApp/Access/requirements.in --universal --generate-hashes --constraint hermes-constraints.txt --output-file Apps/MacApp/Access/requirements.lock`；临时约束不提交。更新依赖需复查兼容性，不能直接放开 Hermes 的版本。

## 已验证

- Swift 客户端 27 项通过：替代通道字节/错误、分片 UTF-8 SSE、Last-Event-ID、响应上限、写入结果不明时不自动重放，以及既有任务日志和 UI 事件归并。
- Python 45 项通过，另增畸形帧验证通过。真实原生 libwebrtc 与 aiortc 互通覆盖直连、真实 coturn relay 候选、并发、资料状态、事件 5/6 从游标 4 续读、订阅取消、同 operation 经 HTTPS 恢复同 run、设备撤销、不可达 TURN 回退。原始 UUID 大小写差异按值比较。
- coturn 4.18.0 在本机临时构建并绑定测试接口，使用临时认证和限定端口；native probe 确认 selected candidate type 为 relay，同时观察到 TURN allocation 与数据收发。仅本地验证，不等于真实运营商 NAT 或公网 TURN 验收。
- Mac Debug、iPhone Simulator、iPhone Release 构建通过；Release 手机/内嵌 Watch/Widget 的 29 项静态检查通过，版本 1.23.0。

- iPhone 专用模拟器默认字号 UI：首次体验、实际 WebRTC 直连显示、记忆同步、Mac 回复/工具进度、手机退出后 Mac 产出真实文件、重开恢复同一 run 与草稿，2 项通过、0 失败。另 1 项 QR 图片配对测试因未启动其专用 18778 fixture 按既有条件跳过；本轮使用真实 PairingStore 设备批准和私密的一次性模拟器注入。

尚未进行真机跨公网、手机切换 Wi-Fi/蜂窝或生产 TURN 服务验收。测试结束关闭并删除专用模拟器，停止本轮合成模型/Gateway、Access 和临时 TURN，不触碰其他 Mac 运行目录。
