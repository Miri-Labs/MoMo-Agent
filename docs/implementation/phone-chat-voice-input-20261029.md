# 手机版聊天语音输入恢复

旧 main 的 `207f0062`（2026-10-20，合并提交 `33641943`）加入了本地听写；`4845047c` 随后修复了与录音资料处理争用队列的问题。当前首发基线仍保留 `ChatVoiceInput`、`ChatMicrophoneRecording`、`ChatVoiceInputView` 和 `SpeechEngine.dictate`，但远程聊天迁移后没有把入口接到 `ClientComposer`。

本次在手机版输入框的发送按钮旁恢复麦克风，复用现有手机端识别模型及权限文案。点按开始录音，勾选完成后将结果追加到草稿，恢复键盘，由用户编辑、发送；不会自动提交消息，也不要求 Mac 在线才能听写。已有附件和草稿保留。录音/识别时隐藏草稿输入框与发送按钮，只显示语音面板，仍可取消；权限拒绝提供打开设置入口。

录音前停止资料回听。切换聊天 store、离开聊天页、打开设置/桌面/附件预览、进入后台时取消当前录音或识别，沿用 generation 校验丢弃迟到结果。语音面板显式设置 accessibility contain 分组，保留取消、完成按钮各自的可访问性标识。

按用户要求，对外版本保持 0.0.1，新安装包仅递增内部构建号。公开 main 保持一个首发 commit。Mac 共用输入框保持原有行为，语音依赖仅在 iOS 编译分支引入。

## 验证

- Xcode 27、iPhone 17e / iOS 27 模拟器：Debug 构建通过。
- MoMoAgentMac / macOS Debug 构建通过。
- `ChatVoiceInputTests` 共 7 项通过：完成仅一次、取消识别、迟到授权、拒绝权限、无语音重试、识别超时，以及实际模型识别固定中文音频。最后一项返回「开放时间早上9点至下午5点。」，使用打包的 Sherpa 模型，不替换识别结果。
- 输入框 UI 回归通过：44pt 麦克风按钮、真实录音面板、取消、打开设置、切后台、权限拒绝均保留原草稿；录音期间草稿输入框不可见。loopback 假服务确认消息提交次数为 0。截图检查了输入、录音和错误三个状态。
- 功能开发阶段已核对 Debug 手机、内嵌 Watch 和 Widget 的包内版本一致；最终安装使用另行生成的 0.0.1 Release 包。
- SwiftUI 静态扫描没有 high 项；固定图标字号与 44pt 点击区域沿用现有样式。

UI 回归沿用 `Tests/AgentRuntime/serve_chat_interaction_fixture.py`，仅连接 loopback 假服务。启动服务后把其 `phone-pairing.json` 放入测试 App 的 Documents，命名为 `momo-simulator-pairing.json`，通过 MoMoAgentRemote scheme 运行 `ChatInteractionTests/testVoiceInputKeepsDraftWhenCancelledOrLeavingChat`。使用测试专用 run ID，重复运行前仅清理对应的 `Library/Caches/MoMoAgentUITests/5F12C378-A804-4E20-A46D-213FE37495AB` 目录并重新放入配对文件。

模拟器与固定音频验收不代表真实手机的麦克风、蓝牙路由和噪声环境验收。真机安装与版本回读单独记录。

## 真机安装

2026-10-29 已生成签名的 0.0.1 Release 包，并通过原包检查器的版本、模型和 Release 资源检查。该检查器默认核对公开 Bundle ID，本机安装按设备回读及现有 `Local.xcconfig` 逐项复核旧身份 `com.watchmylife.ios`、Watch/Widget 身份、后台任务标识与伴随关系，29 项检查通过，签名和 provisioning profile 有效。原位覆盖安装成功，手机应用清单回读 MoMo Agent 0.0.1；未卸载或清理应用数据。首次自动启动被系统以 Locked 拒绝；解锁后已成功启动。尚未进行真机麦克风体验验收。
