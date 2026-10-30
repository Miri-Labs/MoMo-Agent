# 手机 UI 测试

2026-10-15：产品计划功能已退役，付费 UI 旅程现为 ASR → 直接回答 → 来源回听 → 重启恢复聊天，不再检查计划页面。下文旧计划步骤保留为历史说明，当前执行以 Swift 用例为准。

普通 UI 旅程使用独立 UUID 档案和公开音频，验证转写、回放、重启、删除、计划编辑、系统分享及容量。测试不连接 Watch。运行命令与模型准备见 [iPhone 集成测试](../iPhoneIntegrationTests/README.md)。

## 聊天输入区与实际软件键盘

`PhoneComposerHardwareKeyboardTests` 是显式启用的硬件按键诊断：仅在 **test runner** 环境设置 `MOMO_RUN_HARDWARE_KEYBOARD_DIAGNOSTIC=1` 后执行，默认明确跳过，不计验收通过。Xcode 27 的 XCTest `typeKey(.return, modifierFlags: .shift)` 与 Device Hub 直接按键观察到了不同结果，尚未定位差异所在层；保留精确换行、六/七行高度、未发送与重启断言，不能用普通文本插入代替硬件按键。原始 SwiftUI 输入框的直接两行观察及剩余边界见[本轮记录](../../docs/implementation/watch-capture-reliability-20261016.md)。

`PhoneNavigationTests.testComposerDraftRemainsEditableAfterNavigation` 验证普通字号下的多行草稿、键盘上方操作可达性、离开页面返回后的完整草稿及继续编辑，不发模型请求。按 2026-10-16 用户要求，当前测试不再包含大字号或辅助字号用例；下面已执行的历史结果和截图保留原样。VoiceOver、减弱动态效果及普通字号的可访问性检查继续保留。

运行前在专用 iPhone 的 Device Hub 确认软件键盘可见：必要时断开 Hardware Keyboard，聚焦输入框后使用原生 Toggle Software Keyboard，并实际核对屏幕出现 QWERTY。这是测试前环境准备；自动用例运行期间不再操作宿主 UI。仅有 `app.keyboards` 元素不代表键盘在屏幕内，硬件键盘模式可能仍暴露零可见区域的 AX 元素。

用例先确认键盘存在，再最多等待 45 秒至 `hittable`；随后仍严格要求键盘与 App frame 的交集高度大于 100pt，并核对输入和发送控件可达。超时或不可见必须失败，不改成可选检查，也不靠增加产品延迟掩盖。返回后点击输入框可以将光标放在中间，验证要求新增文本只出现一次，移除新增部分后逐字等于完整原稿，而非假设系统总把输入追加到末尾。

证据分轮保留：Phone02 五项计划/录音/设置通过、两个键盘门槛失败；Keyboard03 两项仍未进入实际软件键盘场景；`20261015-mobile-design-phone-keyboard-04` 的两个实际键盘门槛和可达性已通过，最终仅错误的“必须尾部追加”断言失败。修正该预期后 `20261015-mobile-design-phone-keyboard-05` **2/2**，0 跳过/运行时警告，XCTest 42.526 秒，336 项输入稳定；相对 Phone02 只有测试变化，未改产品行为。普通与最大字号 QWERTY 截图分别保留。紧凑叶子导航的后续 `20261015-mobile-design-phone-inline-06` **2/2** 另记，不能把这些轮次合称一次 7/7。

## J02：真实 Agent UI 旅程

`PhoneLiveAgentJourneyTests.testRealASRAnswersThroughChatWithoutCreatingArtifacts` 补齐实际界面操作：

1. Debug 导入公开 `zh.wav`，在资料页等到生产本地 VAD/ASR 的真实正文。
2. 返回聊天，输入 `Make and save a visit plan based on what I just heard.` 并点击发送。任务不复述时间，也不提示模型应该列哪些字段；测试不直接调用 AssistantModel 或 Pi。
3. 等待正式 Pi runtime、生产提示词和工具完成真实 OpenRouter 请求。
4. 从侧栏打开唯一保存计划，核对时间与待确认项。
5. 打开计划来源，逐字对照实际 ASR 正文，并操作原生回放和停止。
6. 终止并重新启动 App，核对计划正文、来源和聊天记录仍然存在；不再发模型请求。

`live-ui-agent-01` 已实际执行，目标 UI 用例 1 项通过、0 跳过、0 失败。模型为 OpenRouter 的 `anthropic/claude-sonnet-4.6`，本次网络模式为 `direct`。`run.json` 的 `accepted=true`，凭据文件删除、宿主停止和隔离档案清理均为 `true`。这证明真实 UI 操作、ASR、模型调用、保存计划、来源回放与重启链路通过。

人工复核未通过内容语义与阅读呈现验收：实际 ASR 是“开饭时间早上9点至下午5点。”，保存计划和最终回答却将“开放/开饭时间”列为已确认信息，并建议按 9 点开门到达。原稿没有确认开放时间或开门时间；有效来源引用不能证明这些推断成立。计划页还直接显示 `##`、`###` 和 `**` 等 Markdown 标记。J02 当前只通过操作与持久化链路，不能登记为内容质量通过。原始证据及截图见下文和[真实模型验收记录](../../docs/implementation/live-agent-e2e.md#j02真实-ui-派活结果)。

`ios-tests-18` 的 3 项 Debug 凭据文件测试、5 项草稿测试和 2 项鉴权边界测试全部通过，未调用外部 API。本条 UI 旅程使用公开单文件音频；已记录的首词识别错误保留原样。它不验收 Watch 采集、WatchConnectivity、真机后台或 18 小时运行。

独立 runner 的 16 项 Python 自检已通过，覆盖凭据权限与清理、两版 xctestrun 路径迁移、来源或模型不符时拒绝验收，以及失败诊断。自检使用合成 SQLite 数据和受控进程结果，只验证 runner 的判定与清理，不计作产品或模型验收。命令为 `uv run Tests/Support/test-run-live-ui-agent-e2e.py -v`。

## 凭据与运行

独立 runner 安装已有的 Debug 测试产物，将指定凭据写入 App 的固定临时文件 `tmp/live-ui-agent-credentials.json`，权限为 0600。测试进程仅收到非敏感 run ID。密钥不经过启动参数、环境变量、输入框或剪贴板。App 只在 Debug、有效隔离 run ID 和显式开关同时成立时读取；文件类型、权限、大小与身份不符即拒绝。

Debug 配置复用正式 Provider 注册和 Pi runtime，只把凭据存储替换为内存。`direct` 仅影响本次测试的 URLSession，不修改系统代理。凭据文件保留至重启步骤结束，再由 runner 的 `finally` 删除；默认 App Keychain 不写入本次密钥。新 loader 与配置入口不进入 Release。

先生成工程并完成 ad-hoc 签名的 Debug `build-for-testing`，再运行：

```sh
uv run Tests/Support/run-live-ui-agent-e2e.py \
  --credential-env-file /绝对路径/独立测试凭据文件 \
  --model anthropic/claude-sonnet-4.6 \
  --simulator SIMULATOR_ID \
  --derived-data DerivedData \
  --network-route direct \
  --output /绝对路径/全新结果目录
```

凭据文件只需包含一个 `OPENROUTER_API_KEY`。不要把密钥填进上述命令。普通 UI 测试未收到 runner 的 run ID 时，此收费用例明确跳过。

## 证据与清理

自动链路验收同时要求目标 UI 用例 1 项通过、0 跳过、0 失败，以及本次隔离档案中的真实 ASR、Pi 模型与工具、计划来源核对通过。UI 截图和 JSON 附件记录实际正文、回放及重启步骤。runner 在停止宿主后只读实际 SQLite，导出允许的证据字段；不复制原始 Agent 数据库、网络任务或凭据存储。`run.json` 是自动链路验收结果，`evidence.json` 保存核对字段；即使计划或来源核对失败，`diagnostics.json` 仍保存本次允许导出的模型回复、工具与提交状态，不导出原始服务错误或思考内容。

本轮证据位于本机 `mizzen/mizzen-insight/tmp_agent_output/20261014-momoagent-xcode/live-ui-agent-01/`。`evidence.json` 保留实际 ASR、计划正文、模型回答与工具记录；`attachments/4A5925A0-6C19-4552-B450-E450BA82392D.png` 是保存计划截图，显示上述推断与原始 Markdown；`attachments/CA544409-86B1-4E12-8EE5-55BF6C9C0A2F.png` 是来源播放截图。截图名称与测试身份可在 `attachments/manifest.json` 核对。

异常、Ctrl-C 或 SIGTERM 也进入清理：删除原容器和重新安装后容器中的凭据，停止宿主，再清理本次隔离目录。若不能确认宿主已停止，保留仍可能打开的数据库并把清理失败写入结果，不强删。SIGKILL 或主机关机无法执行清理；下次运行发现残留凭据时拒绝覆盖，需先处理残留。测试失败不记为模型能力通过；自动断言通过后仍需人工复核回答与计划语义。

Release09 构建与 10 项产物检查已通过；新增凭据文件、开关和配置方法标记均未进入产物。后续 Release 继续检查这些入口缺席，且测试参数不能启用导入。录音详情布局保持当前实现，新布局仍是[设计提案](../../docs/plan/recording-detail-product-design.md)。
