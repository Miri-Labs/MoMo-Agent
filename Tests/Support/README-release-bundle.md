# Release 产物静态检查与检查器自检

从仓库根执行，Python 使用 `uv run`。检查器只读 App；报告必须写入 App 外的新文件，不覆盖已有证据。

```sh
uv run Tests/Support/test-verify-release-bundle.py -v

uv run Tests/Support/verify-release-bundle.py \
  --app DerivedData/Build/Products/Release-iphonesimulator/MoMoAgent.app \
  --output tmp_agent_output/<本轮独立目录>/release-bundle.json
```

先创建本轮独立目录。检查器退出码：`0` 表示所有已登记的静态检查通过；`1` 表示检查失败或输入/工具无法完成检查；`2` 表示报告路径已存在或位于 App 内，没有执行检查。以 JSON 中的 `status`、`checks`、`errors`、`unchecked_assertions` 为准。

## 自检范围

Gmail 使用用户自备客户端：实际包必须声明 `MoMoGmailAuthentication = userProvided`，且不包含 `MoMoGoogleClientID`。静态检查不要求使用者已配置邮箱；动态回调和实际账号授权分别验证。

23 个自检用例包含 Gmail 配置模式校验，并使用临时合成 App 目录、合成模型字节与独立 pin 文件。主可执行和嵌入库使用本机 `/usr/bin/true` 的真实 Mach-O 字节，让正常路径实际经过 `xcrun lipo -archs`；不构建、安装或启动 App，不启动模拟器，不调用模型 API。测试完成后删除合成目录。

- 合格合成基线必须完成所有已登记的检查，手机和嵌入 Watch 可执行均进入结果。
- 缺失的 Watch、错误 bundle ID、缺失/非 Mach-O/路径越界的可执行文件必须失败。
- 手机、Watch、嵌入 dylib/framework 中的 Debug 标识必须失败；逐一验证全部已登记标识跨扫描块边界仍可发现。
- 两端的 fixture、凭据文件名、测试 bundle、debug dylib 和模拟器测试目录必须失败。
- 文件/目录符号链接与不可读目录必须拒绝，不能跳过后报告清单完整。
- 逐个模型与模型清单的缺失、改动、非法 pin 必须失败。
- `Speech/` 必须恰好包含 Core ML 生产清单中的 12 个文件（含嵌套目录）；旧 ONNX 识别权重和词表也须拒绝。额外普通文件、隐藏文件或目录即使不在 fixture 黑名单中也必须失败。许可和出处单独保留于 `SpeechLicenses/`。
- 后台模式、后台任务 ID、Watch companion 配置、麦克风用途与三个隐私理由分别检查；非法 plist 或字段类型不能使检查器意外退出或误报通过。
- 架构工具失败、超时、缺失及非法输出必须使检查失败。
- CLI 成功/失败退出码与 JSON 一致；不覆盖旧报告，不在 App 内写入报告。

2026-10-14 本机独立自检为 **16/16 通过**。首次运行暴露了两个检查器问题，修正后重跑通过：不可读子目录会被 `os.walk` 默认跳过；非字符串麦克风用途会抛出未处理异常。原始失败和修后结果分别保留在 `tmp_agent_output/20261014-resume-release-verifier/selftest-before.log` 与 `selftest-after.log`，不入 Git。

自检通过只证明这些检查器判断分支，不能证明产品 Release 已通过。产品还需要从最新源码单独构建，再对实际手机及其嵌入 Watch 产物运行检查。静态检查不包含安装启动、运行行为、签名/entitlements、真机、18 小时采集、App Store 归档或发布，也不承诺识别任意未知密钥。`MARKERS` 和 `FORBIDDEN_NAMES` 只涵盖明确登记的测试入口和文件名。

Xcode 27 实际复验：`tmp_agent_output/20261014-xcode27-release-01` 构建成功，但检查器发现模型 folder reference 把 `Speech/test_wavs/zh.wav` 带入产品，因此失败。原 App 仍保留于 `DerivedDataRelease27`。源配置随后改为四个明确的 Copy Files 输入，公开 fixture 留在原本机模型目录，用来验证打包不会受其污染；准备脚本也不再提取测试音频。新的 `DerivedDataRelease27-02` 从空产品目录构建，包含修正后的录音引用按钮命中范围。第二轮 **构建成功、19/19 静态检查通过、17/17 检查器自检通过**；手机和嵌入 Watch 均为 SDK 27 的 arm64 模拟器产物，许可与出处独立保存。证据在 `tmp_agent_output/20261014-xcode27-release-02`。

后台声明静态检查不等于系统注册成功。本轮 Debug 日志的 continued-task wildcard 注册被系统拒绝；两份 plist 确实声明了该通配符，但代码注册时未展开为具体任务 ID。该问题与当前 `foregroundOnly` 策略的影响见同轮 `background-registration-review.json` 及 [Apple WWDC25 注册说明](https://developer.apple.com/videos/play/wwdc2025/227/?time=809)。本轮只读核对，未修改后台策略或宣称后台验收通过。

后续 Release03/04：`tmp_agent_output/20261014-xcode27-release-03` 从新的 `DerivedDataRelease27-03` 产品目录构建，依赖缓存单独 APFS clone；Release04 在它上面只增量重编新的 Agent 提示词。两轮均构建成功、19/19 静态检查及 17/17 自检通过。两份完整 App 已各自 APFS clone 到对应证据目录，旧包不被后续构建覆盖；每份 114 个实际文件均保存 SHA-256，新增强杀 hook/测试类标识另行扫描，`Speech/` 恰好四个固定生产文件，源目录中的公开测试音频仍保留但没有进入产品。

Release04 的已记录源码在构建前后完全一致，`PiAgentHost.swift` SHA-256 为 `771dd8f6b85abbaa7d7ebff2bc505114b2e61290b940d9820a983d20364d2f2f`。Release03 编译时对应 `4ed51a3e38b795f3543591067279058e59e2cc70a8162ca3c6a70bcda171188e`；03 构建结束后才修改此文件，差异在报告中保留。两轮均包含后来按具体 continued ID 注册的实现，受控后台测试和仍未启用的设备策略范围见 [后台注册复核](../../docs/implementation/background-registration-review.md)。本段只报告构建与静态检查；安装启动和真实 API 语义质量结果应单独列出。

Release04 另在既有、已清理的 HTTPS 专用 iPhone Simulator `5E5AC9B8-8798-4148-BA5C-B78A959C60C2` 完成实际安装与无测试参数启动，没有注入 API 凭据或修改信任。实际安装的手机、Watch 可执行及手机 plist 哈希与保留包一致；进程持续存在，启动时间窗 413 行日志未见旧 `Registration rejected`。证据为 `launch-01/`。当时 Mac 锁屏且 UI 工具无法自动解锁，首页、设置、资料和计划的页面检查仍 **pending**，不能用进程存活替代。已停止 App 并关闭专用 Simulator，保留其原有测试资料，不触碰主 iPhone。

用户随后解锁后，同一 Release04 在专用设备完成四页真实 CUA 导航与截图：聊天首页、设置、转录资料空态、计划空态均正常显示，默认字号下未见重叠或截断，也没有可见 Debug 入口。`visual-01/` 保存四张截图、页面可访问性文本和独立报告；因此上述锁屏 pending 已解除。没有填写密钥、发 API 请求、创建档案或修改设置，结束后再次停止 App 并关闭专用设备。本轮补充日志导出被关机中断，空日志标为不完整，后台注册核对仍引用此前完整的 `launch-01/` 日志；四页检查不等于完整无障碍或运行功能验收。

Release05（`tmp_agent_output/20261014-xcode27-release-05`）复用 `DerivedDataRelease27-03` 增量构建，纳入顺序音频读取、未读尾段重新校验 SHA-256，以及后续 Agent 提示词/工具修订。355 个已记录构建输入的前后哈希一致；真实构建成功，手机与嵌入 Watch 的 **19/19 静态检查、17/17 检查器自检通过**。保留的独立 App 快照含 114 个文件、298,646,158 字节；整个包另扫描 23 个新增测试/hook/诊断标识均未命中，`Speech/` 仍恰好四个固定生产文件，源模型目录中的公开 `test_wavs/zh.wav` 未混入包。完整文件哈希、源码差异和独立资源核对随证据保存。根代理对已授权凭据做的独立精确字节扫描也未命中，单独记录于 `credential-bundle-scan.json`；它不代表任意未知密钥检测。Release05 本轮没有安装或启动，不能沿用 Release04 的四页截图作为新版运行验收。

Release05 随后在既有 HTTPS 专用设备完成实际安装/启动和首页截图检查；手机/嵌入 Watch 可执行与两份 Info.plist 的 SHA-256 均与快照匹配。首页显示正常，无可见 Debug 入口或启动错误，未注入凭据、发请求或操作其他页面。`launch-01/` 保留证据。启动日志导出等待 60 秒后超时且文件为空，因此本轮**不能确认有无后台注册错误**；不能复用 Release04 日志冒充新版结果。因磁盘/内存压力按主任务要求停止继续采集，App 已终止、专用设备已关闭；没有删除原测试资料或改信任。设备宿主 AX 树本次未返回 App 后代，此次只作实际截图核验，不计作 VoiceOver/AX 通过。

资源清理补充：上述专用设备 `5E5AC9B8-8798-4148-BA5C-B78A959C60C2` 随后交由根代理删除以回收空间；设备删除的实际结果由根代理另存。`launch-01/cleanup.json` 仅记录本轮已实际完成的 terminate/shutdown，历史截图和哈希仍以原设备 ID 标识，不再对该 ID 执行后续验证。

手机 Release06（`tmp_agent_output/20261014-xcode27-release-06`）纳入两处 SQLite 自动回滚后的原始错误保留修补，复用 DD03 增量构建成功。相对 Release05 的生产差异仅为 `MoMoArchive/SQLite.swift` 和 `MoMoRecording/Ledger/RecordingDatabase.swift`；355 项构建输入前后哈希一致。**19/19 静态检查、17/17 检查器自检通过**；独立 App 快照 114 文件、298,649,470 字节，四个生产模型 hash 匹配，额外 23 个 Debug/测试标识全包扫描无命中。根代理的已授权 key 精确字节扫描也无命中，单独报告已引用。随后根任务已实际安装并核验首页，四项安装哈希与快照一致；该包早于后来的音频 tap 修补，原证据完整保留。

最新 Release07（`tmp_agent_output/20261014-xcode27-release-07`）相对06唯一生产源码改动是 `AudioCaptureEngine.swift` 的 tap 显式 `@Sendable`，避免在音频后台回调中继承 MainActor 隔离。复用 DD03 增量构建，355项输入前后哈希一致；19/19静态检查、17/17检查器自检及全包23个额外标识扫描通过，四个生产模型匹配，独立快照114文件、298,649,470字节。根任务独立扫描已授权key的精确字节，零命中。随后已实际安装启动并核验首页，四项安装文件哈希与快照一致，见同目录 `installation.json` 和 `home.png`；未重复完整页面导航。构建与检查通过不能替代Watch有效帧、封口和暂停恢复验收。
