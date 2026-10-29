# Rakazo 通知与连接交互：2026-10-24 实施交接

状态：源码研究交接已完成，后续实现与验收见 [Beta 1.31.0](apns-rakazo-1.31.0.md)。以下“当前缺口”描述研究时的 MoMo 基线 `403618c058181978a32ee650b77ebd106c2d08e6`（Beta 1.30.1），不是实现后的状态。独立分支 `codex/hermes-app-20261021`，现有 `.pen` / `Models` 未动。

本次只落实两项：**接通 APNs 的最终结果/待确认通知**，以及**将连接故障变为明确、可恢复的状态**。已有 shared conversation、服务端 completion wake、Hermes 记忆与嵌入式 Tailscale 不重做。

## 1. 源码基线与已核实结论

通过 GitHub connector 查询官方 `elie222/rakazo` 最新 main，固定 `1e92d28aab97c22e396348a64b2fc2a1e47c9c68`。原 `5ef4476d96e0eea64d3b27833ff7f2b201f918da` checkout 保留；新只读目录为 `/Users/syh/Documents/Codex/2026-10-21/jie-he/research/rakazo-20261024`。两次快照之间变动较多，但下面的 push、通知点击、前台抑制、computer-refresh 文件没有变化；本次均按新 SHA 重新读取。

| 主题 | Rakazo 实际实现 | 对 MoMo 的启发 |
|---|---|---|
| 通知触发 | `executor.ts` 在持久 finalize 后才推 completion；仍有 continuation 时不发结束通知；approval pause 落库后发 help；可重试失败不立即作最终失败通知 | 最终回复、失败、待确认是通知事件；中途“我来处理”不是完成 |
| 收件对象 | `expo-push.ts` token 绑定登录 session，发送前检查 session 到期，再读 token 防止换账号竞态；旧 token 的失败只删除仍匹配的旧记录 | MoMo 绑定已批准的配对设备；撤销后不能再注册/发送；旧失败不能删除新 token |
| 多设备限制 | 每 user 一个 token 文件，新注册覆盖旧值 | 不照搬这一限制；MoMo 的配对本身支持多设备，按设备建 delivery |
| 前台抑制 | `live-notifications.ts`：前台 completion 全部静默；同一已打开 thread 的 help/failure 也静默；没有打开的其他 thread 可提示 | MoMo 只在目标消息/控制卡片实际可见时抑制；在转录页或还未同步成功时保留提示 |
| 点击 | `open-notification.ts` 用 request identifier + deliveryId 去重，冷启动和监听器不会双导航；先检查登录，关闭设置页再打开对话；失败保留可重试，退出账号的旧点击不在将来自动重放 | 点击携带 opaque 定位信息，恢复配对连接后读取正式消息，不把推送正文直接变成聊天 |
| 失效/重试 | Expo 429/5xx 有限退避，DeviceNotRegistered 删除匹配 token；ticket 后另查 receipt | APNs 用自己的响应语义，不照搬 Expo ticket API；接受、失效、重试、已读不同 |
| 通知可靠性边界 | 普通 `notifyRun` 失败仅日志，并非完整持久推送 outbox | MoMo 复用自己的 outbox，不能因为“参考 Rakazo”删掉已有恢复能力 |
| 聊天重连 | 前台从已应用 cursor 接续；取消旧请求、session generation 隔离；重试从250ms至5s，尊重 Retry-After；非408/429的4xx停止自动轮询 | 保留本地消息/草稿；鉴权失败不永远显示“正在重连” |
| 电脑画面 | `computer-refresh.ts` 用 revision/lifetime 忽略旧响应；普通状态轮询不反复换屏幕URL；后台暂停，回前台立即读，403/404等待用户操作 | 采用请求代际与故障分类，不重写当前桌面传输 |

源码：[通知时机](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/adapters/src/executor.ts#L8502-L8554)、[通知过滤与失败](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/adapters/src/executor.ts#L8916-L8977)、[token与provider](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/adapters/src/expo-push.ts)、[前台](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/apps/mobile/lib/live-notifications.ts)、[点击](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/apps/mobile/lib/open-notification.ts)、[聊天续接](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/apps/mobile/app/thread.tsx#L1654-L1772)、[重试策略](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/packages/core/src/retry-policy.ts)、[电脑恢复](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/apps/mobile/lib/computer-refresh.ts)。

Rakazo 手机连接仍是 server URL + 受鉴权 API；`endpoint.ts` 允许 loopback/LAN/Tailscale 地址的 HTTP，公网要求 HTTPS。没有发现需要改掉 MoMo TailscaleKit/扫码流程的新依据。[连接源码](https://github.com/elie222/rakazo/blob/1e92d28aab97c22e396348a64b2fc2a1e47c9c68/apps/mobile/lib/endpoint.ts)

## 2. MoMo 当前缺口

| 文件 | 当前状态与接入点 |
|---|---|
| `Apps/MacApp/Runtime/conversation_store.py` | 有 notifications 表、pending/retry/accepted/disabled、指数退避。但主键只有 message_id；`append_assistant` 对所有中途/最终助手消息入队；缺设备、事件类型、失效token和独立delivery。 |
| `Apps/MacApp/Runtime/personal_agent.py` | `set_notification_provider` 从未接真实 provider，`CAPABILITIES.system_push` 固定 false。`observe.interim` 和 `project` 共用 append；需要在原生 terminal/control 状态明确后生成通知。 |
| 同文件 `maintain` | 在同一个锁/维护循环中 await `deliver_notifications`，APNs慢/超时会拖住新消息投递、completion核对和投影；必须把通知网络I/O移到独立有界发送循环。 |
| `Access/pairing_store.py` / `access_server.py` / `rtc_transport.py` | 已有受信设备ID，代理覆盖 `X-MoMo-Device`，两条传输都由授权 token 派生。适合注册/解绑；发出通知时也需复核当前配对状态。 |
| `Apps/iPhoneApp/Bootstrap/PhoneAppDelegate.swift` | 仅应用启动和Watch接收，无 APNs delegate/通知点击。可加入 `UNUserNotificationCenterDelegate` 与注册结果回调，保留现有后台接收启动。 |
| `Apps/iPhoneApp/Resources/MoMoAgent.entitlements` / `project.yml` | 当前只有 HealthKit，无 aps-environment。Beta topic固定 `com.momoagent.ios.beta`；APNs environment要与实际签名一致。 |
| `PhoneRemoteAgent.swift` / `PhoneRootView.swift` | 有恢复配对与foreground入口；tab选择为View私有state，通知点击还无法切到chat/关闭settings/等待连接。需一个小的 pending notification target 状态。 |
| `RemoteTaskStore.swift` | `markVisibleMessagesRead()` 没有任何UI调用且默认标到整个已下载cursor，不能直接当成“看见了”。foreground固定每2秒refresh；401/403没有独立连接恢复状态。 |
| `PhoneRemoteView.swift` / `RemoteTaskRecoveryView.swift` | 通用错误以红字显示；recovery仅针对本地task，另一端发起或服务端产生的任务可能没有可见重试入口。保留现有审批/补充/停止卡片，不重造。 |

## 3. 改造一：APNs 最小完整链路

```text
Hermes原生最终回复 / 等待用户 / 最终失败
  → 产品事件落库 → 按有效配对设备建delivery → 独立发送循环 → APNs
  → iPhone系统通知 → 点击 → 验证当前Mac/assistant身份 → 恢复Tailscale并补读
  → 显示真实消息/控制卡片 → 对已呈现范围确认已读
```

### 服务端事件与设备合同

- 保持 assistant interim 立即展示，但不创建 completion push。最终事件取已settled原生run；若有后台委派仍待报告，短答不是“任务完成”。真实completion续跑报告落库后再提醒，推送文案用“MoMo 有新回复”，不把所有terminal run叫任务完成。
- `needs_input` 取当前 `pending_controls`，稳定键包括 run/admission、execution_generation、prompt_id；同一控制不随每秒poll反复推。通知只能打开卡片，不能在锁屏直接允许工具。终态失败提示与普通可恢复连接故障分开。
- 最小新增 `push_devices(device_id, token, topic, environment, registration_revision, registered_at, enabled)` 和 `notification_deliveries(delivery_id, event_key, device_id, token_revision, state, attempts, next_attempt, last_reason)`。唯一 `(event_key, device_id)`。保留旧 notifications 作为历史，不把 disabled/legacy backfill 批量补推。
- 注册建议复用 `/momo/v1/conversation/push` 的 GET状态、POST注册、POST解绑子路径；请求只需token与构建metadata，device_id从Access注入且不得信任body同名字段。topic/environment服务端白名单+包内构建值交叉校验，不能允许客户端选择任意App。
- provider若在 runtime读取device表，需用只读配对查询或既有本地IPC复核approved；不要把客户端上一回注册成功当作永久授权。撤销配对同时将关联delivery取消，发送前再次验证。token轮换按revision更新；旧APNs响应只处置旧revision。
- delivery状态至少区分 pending/retry/accepted/invalid_token/suppressed/expired/disabled；APNs200只叫accepted。无有效设备是无收件人，不返回成功。网络重试不生成新的模型run或新的event_key。
- 独立发送task只处理有限批次，单次请求有超时，数据库事务不跨网络await；维护循环和新消息接收不等待APNs。重启恢复pending/retry；同一delivery使用稳定 apns-id，重发可能被网络重复，不能宣称APNs恰好一次；客户端按delivery_id防重复导航。

### APNs provider与部署边界

本次推荐最小独立通知gateway，APNs私钥只在该服务端读取；Mac仅持有分实例、受限、可撤销的凭据，不新建用户账号体系。根侧检查尚未找到既有 `.p8` / 推送服务；可先交付可运行gateway与fake provider验收，不能称真机推送已完成。开发者在自己机器验证时可以私有运行gateway，但私钥仍不进入App bundle、仓库或日志；不能把开发者团队私钥下发给用户的Mac。

Rakazo可借鉴的是**受鉴权注册 + 独立provider + 发送前收件资格复核**，不是它的整个Expo/账号系统。MoMo最小gateway合同如下：

| gateway接口（建议） | 受限合同 |
|---|---|
| `PUT /v1/devices/{opaque_device_id}` | Mac用运维配置的instance credential注册已配对手机token/revision；服务端凭据固定绑定instance，不接受body改归属；topic/environment由服务端白名单决定。注册ACK丢失可按相同revision重试。 |
| `DELETE /v1/devices/{opaque_device_id}` | 只撤销本instance设备；同步取消未发delivery，幂等。Mac本地先撤销以立即止发，再持久重试远端删除；离线撤销不能被宣传成gateway已经同步完成。 |
| `POST /v1/notifications` | 只引用本instance已登记的device、稳定delivery_id和白名单kind/opaque定位字段；不允许请求带任意token、URL、topic或任意通知正文。gateway生成短文案，验证device当前有效，以 `(instance,delivery_id)` 去重；同键不同payload拒绝。返回accepted/retry/invalid_device等明确结果。 |

gateway用一个小SQLite保存instance credential摘要、设备登记和delivery回执即可；Mac现有outbox负责重试和调度，避免再造一套任务执行/Agent层。未成功的请求可以由Mac原delivery重试，已accepted的原回执可重放；APNs接受后gateway落库前崩溃仍有重复风险，保留稳定apns-id/collapse-id和客户端delivery去重，不承诺端到端恰好一次。服务端credential只能操作自己的实例与设备，限制kind和速率；配置中的凭据与真实token不进日志。撤销instance credential立即停用该实例的gateway访问。

gateway实现APNs provider优先复用现有Python能力 `httpx`、`PyJWT[crypto]`，显式确保HTTP/2依赖；不能只因为源码有httpx就认为h2可用。gateway私有配置保存 Key ID、Team ID、key path、固定topic/environment；Mac仅保存gateway地址与自己的实例凭据。gateway未部署/未配置时把软件接线与已实际送达分开报告，保留 `system_push=false`；configured/registered/accepted状态分别表达，不能因为存在provider对象就认定配置可用。

APNs使用HTTP/2 TLS，ES256 token可复用并按时刷新；sandbox/production由签名环境匹配，Beta名称本身不决定环境。payload不放转录、健康详情或工具命令，只放简短提示及 `v, kind, instance_id, assistant_id, conversation_id, message_id?, run_id?, control_id?, delivery_id`。显式alert push；不依赖silent push启动Tailscale或运行Agent。合法topic来自受信配置。

使用当前已登记token；410 Unregistered按返回timestamp和登记revision有条件失效，避免删掉刚刷新的token。400/403配置错误不得无限重试；429/5xx/网络故障退避；认证过期由provider更新token，不丢消息。已读、已取消、控制已处理或超过有效期的待发事件跳过；队列积压可按同conversation+kind合并提示，正文仍由完整消息同步保证。

Apple依据：[注册与签名能力](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[发送协议](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)、[token鉴权](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)、[响应处置](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)。

### iPhone授权、前台与点击

1. 配对完成后在适当时机请求通知权限，拒绝不阻塞聊天；设置保留简短通知状态/系统设置入口，不增加长onboarding。启动时向APNs重新注册获取当前token，不把历史缓存当成最新token；失败不影响录音。token取得早于配对时在当前进程等待，配对/网络恢复后上报。
2. `PhoneAppDelegate` 启动早期安装UN delegate。前台 `willPresent` 对当前identity检查；目标消息或控制卡片已在可见chat中才抑制banner/sound。不要因为app前台就把转录页上的新回复吞掉；也不以push到达冒充已读。[Apple前台处理](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)
3. 点击只处理默认打开动作。按delivery_id去重，校验当前配对instance/assistant；不从payload读URL、token或指令。关闭settings/desktop覆盖，选chat，调用现有foreground/refresh。冷启动和delegate重复回调只能产生一次导航。
4. Mac暂时离线时显示已有消息和“正在连接Mac”/重试，保留pending target；恢复后补读到目标，再清除target。通知点击不创建新用户消息、不重放已发送任务。已撤销/另一身份的通知丢弃，不能在未来重新配对后悄悄打开。
5. 修正已读合同为 `markVisibleMessagesRead(through:)`，仅在前台chat且内容已呈现时确认；可复用现有阅读位置/renderer消息ID映射seq。若未到列表底部，不把已下载但没看见的后续页标已读。同步失败时不前推。
6. 已读后只清理该conversation中不超过已读目标的通知；不要“删除全部通知”误清另一条较新待确认。badge采用服务端真实未读状态，否则先不设置badge，不能填固定数字伪造。

## 4. 改造二：连接状态与可恢复错误

保留2秒健康轮询与当前传输，增加一个共享错误分类/状态，不另造连接框架：

| 证据 | 状态与交互 | 自动动作 |
|---|---|---|
| 无HTTP响应、超时、408、429、5xx | 连接暂断；保留聊天/草稿，按钮内重试 | 有界退避，前台恢复/手动重试立即尝试，成功重置；尊重Retry-After |
| Access 401 / 已证实配对撤销 | 配对已失效；“重新连接” | 停止自动提交/反复鉴权；保留原operation/session/cursor |
| 权限403、协议不兼容404/405/426/501、业务409等 | 根据操作语义显示权限/升级/回执核对入口 | 不把所有4xx当重连；不能将run不存在等价为整个配对失效 |
| native unknown | 任务结果待核对 | 保留既有unknown处理，不通过重连自动重做 |

接点：`AgentClient.request` 保留HTTP响应的Retry-After（自定义transport与URLSession均需覆盖）；`RemoteTaskStore` 将连接错误与任务错误区分，自动重试只处理可恢复状态；`PhoneRemoteView`/`RemoteTaskRecoveryView` 复用一个简短状态+动作，两端一致。连接generation变化或后台暂停后，旧响应不得清除新错误/写入另一连接；任务提交仍用原operationID。

这项也改善通知点击时Mac睡眠/离线的体验。Tailscale连接正常不等于Mac Agent在线；本次不增加唤醒Mac、临时隧道或HTTPS教程。现有“等待审批期间独立聊天”仍为false，不借此扩大执行权限。

## 5. 交接清单与验收

建议顺序：服务端事件/设备delivery → APNs provider独立worker → 受鉴权注册API/allowlist → iOSdelegate与点击恢复 → 可见已读与前台抑制 → 错误分类/重连 → Beta构建与真实推送验收。

| 验收 | 必须证明 |
|---|---|
| 最终/中途 | “我来处理”与工具进度不推；父代理真实最终回复推一次；有新generation的待确认可再推 |
| 通知不堵聊天 | provider卡住/超时期间，消息照常入队、模型回复照常投影、completion照常核对 |
| 多设备/撤销 | A/B独立delivery；撤销A不影响B；伪造device_id或topic拒绝；失效旧token不删新token |
| 失败与重启 | 429/5xx退避后恢复；200记accepted不记read；重启继续同delivery；无密钥不假报push可用 |
| 点击 | 锁屏、后台、冷启动、settings覆盖、重复delegate、Mac离线再恢复均打开原chat，不发新任务 |
| 前台与已读 | chat中已见消息静默；转录页可提示；只读到可见seq；下载历史不自动全已读 |
| 错误恢复 | 503自动恢复保留草稿；401停止循环并提示重连；旧响应不覆盖新连接；unknown不重做 |
| Beta隔离 | topic、aps-environment、实际签名、手机appID均核对；只安装 `com.momoagent.ios.beta`，正式版不变 |

可扩展现有 `Tests/AgentRuntime/test_personal_agent.py`、`nonblocking_chat_smoke.py`、Access配对/allowlist tests、`SharedConversationTests`/`ConversationDeliveryTests`；新增最小通知策略与点击路由测试。Rakazo参考测试：`expo-push.test.ts` 的多账号token移交/旧失效响应/receipt；`open-notification.test.ts` 的冷启动双回调、设置覆盖、旧登录点击；`live-notifications.test.ts` 的目标thread抑制；`computer-refresh.test.ts` 的后台暂停、旧响应、403/503；`retry-policy.test.ts` 的状态与Retry-After。

本轮仅阅读源码与官方协议，没有运行Rakazo完整测试，没有读取APNs私钥或真实token，也没有验证真机系统通知。实际APNs200、锁屏出现、点击恢复分别留证；模拟provider/编译通过不能代替最后三步。
