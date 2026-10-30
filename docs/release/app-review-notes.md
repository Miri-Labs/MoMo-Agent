# MoMo Agent App Review 说明 / Review Notes

准备日期：2026-10-15。依据：当前生产代码；不是本次真机验收记录。

**提交前草案：不得把 TODO 或未完成的发布条件直接提交给 Apple。** 不包含真实 API Key。审核专用凭据只通过 App Store Connect 审核信息等适当渠道提供，不进 Git、截图或公开文档。

## 提交信息

| 字段 | 当前值／待填写 |
| --- | --- |
| 产品 | MoMo Agent，iPhone + Apple Watch |
| iOS Bundle ID | `com.momoagent.ios` |
| Watch Bundle ID | `com.momoagent.ios.watchkitapp` |
| 最低版本（project.yml） | iOS 18.0 / watchOS 11.0；须与最终 Archive 再核对 |
| 提交版本／Build | TODO：从实际 Archive 读取，不能照抄项目默认值 |
| 审核联系人／邮箱／电话 | TODO：填写可联系的真实信息 |
| 隐私政策公开 URL | TODO：发布已补齐主体与联系方式的政策 |
| 支持 URL | TODO：可公开访问的支持页面 |
| 模型审核配置 | TODO：提供可用的 HTTPS 地址、模型 ID、协议和审核专用 Key，确认余额、地域和有效期 |
| 真机演示视频 URL／附件 | TODO：拍摄 iPhone 与配对 Watch 的实际交互，使用合成测试内容 |

MoMo Agent 没有自己的账号登录。API Key 是第三方模型服务凭据，不能因此向审核人员承诺所有功能无需配置。不得要求审核人员购买自己的 Key 或使用开发者私人生活资料。

## 中文审核说明（补齐发布条件后可用于审核备注）

MoMo Agent 是配套使用的 iPhone 与 Apple Watch 录音、离线转写和个人记录助理。完整录音到转写流程需要配对的 iPhone 和 Apple Watch。Watch 可在手机暂时不连接时录音和保留资料，之后通过 WatchConnectivity 传输；转写与助理界面在 iPhone 上。

应用不要求创建 MoMo Agent 账号。录音及本地转写不需要模型 API Key。只有助理功能需要用户配置第三方模型地址和自己的 API Key；审核专用配置将通过审核信息单独提供。

1. 在配对 iPhone 和 Watch 上安装应用并分别打开。Watch 点击“轻触开始录音”，首次使用允许麦克风权限。录制一段不含个人资料的测试语音。
2. 使用麦克风控制暂停／恢复，录制时可点“标记”；从“更多”选择“结束录音”并确认。录音期间可观察状态、时长与录音指示；后台音频用于持续进行用户已开始的录音。
3. 保持配对设备可通信，在 iPhone 首页的手表状态或菜单中进入录音资料，等待接收和本地转写。转写使用包内 SenseVoiceSmall 和 Silero VAD，无需下载云端转写结果。打开录音详情查看原文和引用、播放可用原音、导出资料或调整原音保留。
4. 打开“设置 → AI 服务 → 连接模型服务”，选择预设或自定义服务，填写单独提供的审核配置。未配置时不预选服务商或模型；预设只填写地址与接口协议，自定义服务需要明确选择协议。点击“连接并读取模型”，选择目录中的模型或手动填写模型 ID，再点“验证并使用”。验证通过且保存成功后使用该连接，也可保存多个独立连接。读取目录会向该服务发送鉴权请求；验证会发送小型合成提示、随机校验值和工具定义，不读取录音、转录或聊天，不执行返回的工具调用，但可能产生少量 API 费用。
5. 在助理聊天页发送问题，例如“请总结最近的记录”，或从转录引用进入讨论。请求会将消息、相关历史、个性与记忆设置、近期／选中转录及工具读取的文字和元信息发送给配置的模型服务。请求不经过开发者模型中转服务器，不自动发送原始音频。API Key 在设备钥匙串保存，并用于对该服务鉴权。
6. “设置 → 个性与记忆”可查看和修改助理性格、关于你及长期记忆。录音详情提供导出、原音保留及“删除录音与转录”；删除会清理关联助理上下文并向 Watch 同步删除控制，离线时可能延后。删除本地资料不能撤回模型服务已经收到的数据。

## English review notes (complete release prerequisites before use)

MoMo Agent is a companion iPhone and Apple Watch recording, offline transcription and personal-record assistant. The complete capture-to-transcript flow requires a paired iPhone and Apple Watch. Watch can record and retain audio while temporarily disconnected, then transfer through WatchConnectivity. Transcription and the assistant run on iPhone.

No MoMo Agent account is required. Recording and local transcription do not require a model API key. The optional assistant requires a user-configured third-party endpoint and the user's own API key. Working review-specific configuration will be supplied separately in review information.

1. Install and open the apps on both paired devices. On Watch, tap “轻触开始录音” (tap to start recording) and grant microphone permission. Record non-personal test speech.
2. Use the microphone control to pause/resume and “标记” to mark. Open “更多” (More), choose “结束录音” (End recording), and confirm. Observe recording status, duration and recording indicators. Background audio supports recording explicitly started by the user.
3. Keep the paired devices able to communicate. On iPhone, open recordings from the home Watch status or menu and wait for receipt and on-device transcription. Bundled SenseVoiceSmall and Silero VAD models perform transcription locally. Open recording details to inspect text and citations, play available audio, export or change retention.
4. Open Settings → “AI 服务” (AI services) → “连接模型服务” (Connect a model service), choose a preset or custom service, and enter the separately supplied review configuration. An unconfigured app has no preselected provider or model. Presets fill only the address and API protocol; a custom service requires an explicit protocol choice. Tap “连接并读取模型” (Connect and read models), choose a listed model or enter its ID, then tap “验证并使用” (Verify and use). The connection becomes active after successful verification and saving; multiple independent connections can be saved. Reading the catalog makes an authenticated request to that service. Verification sends a small synthetic prompt, a random check value and a tool definition, without reading recordings, transcripts or chats or executing the returned tool call. Verification may incur a small API charge.
5. In the assistant, ask to summarize recent records, or discuss a transcript reference. Requests send messages, relevant history, personality/profile/memory, recent or selected transcript text and text/metadata returned by local tools to the configured service. There is no developer-operated model relay and no automatic original-audio upload. The key is stored in device Keychain and authenticates requests to that endpoint.
6. Settings → “个性与记忆” lets you edit personality, profile and memory. Recording details offer export, audio retention and deletion of recording/transcript. Deletion cleans related assistant context and propagates deletion control to Watch, potentially delayed offline. Local deletion does not retract data already received by a model provider.

## 发布阻塞项（内部，不粘贴成已完成的审核承诺）

- [ ] 补齐联系人、政策／支持 URL、实际 Archive 版本及有效审核配置。当前项目没有实现可代替真实功能的内置审核演示模式。
- [ ] 应用内提供易访问的隐私政策入口；当前设置页未找到入口。
- [ ] 首次向 AI 发送前，明确说明具体接收方与数据范围并取得明确许可；服务地址变更后的处理也需核实。当前仅发现设置页静态说明，未发现独立的共享同意流程，不能声称已满足 Apple 5.1.2(i)。隐私政策本身不能补足这个交互。
- [ ] 补齐上文两端真机验收及视频；本次只读审查没有运行设备测试。转写缺模型时会提示失败，必须验证实际 Release 包包含模型和许可证。
- [ ] 核实最终模型提供方的保留、训练及身份关联政策，再填 App Privacy；不得仅以“Key 用户自带／无自建后台”选“未收集数据”。
- [ ] 明确发行地区；大陆备案适用与受理路径尚未获得个案确认，不把本说明当作豁免证明。

## Apple 官方依据（2026-10-15 查询）

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：2.1 审核完整性、2.5.14 录音、5.1.1 隐私政策、5.1.2(i) 第三方 AI 数据共享许可。
- [Provide information for a complete review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review)：外部服务、审核访问与硬件交互演示材料。
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)：本机处理与设备外收集、第三方实践、数据用途和身份关联。
