# 真机安装与同步验证（2026-10-15）

当前工作树包含本会话的 Watch 录制交互及 iPhone 状态卡修改。

- iPhone 17 Pro 已通过有线配对连接；iOS 27.2，开发者模式 Enabled。
- `devicectl` 能识别该 iPhone，未识别物理 Apple Watch。
- 手机上查询未发现 MoMoAgent 开发安装。
- 本机代码签名查询为 0 valid identities；未配置 Config/Local.xcconfig 的开发团队。
- Xcode 当前显示首次 External Agent Access 弹窗，需用户自行选择访问范围，并登录用于签名的 Apple 账号。
- Xcode 27 generic iOS Debug 真机编译成功，包含嵌入的 watchOS App；此次明确使用 CODE_SIGNING_ALLOWED=NO，仅验证代码与打包，产物不可直接真机安装。

构建日志：`tmp_agent_output/20261015-device-sync/unsigned-build.log`。

待签名团队/证书就绪、Watch 被识别后，重新构建签名版本，安装两端，再验证 Watch 开始录音、手机状态更新、结束生成音频、手机接收/回执、转写及重启保留。本轮尚未进行真实录音或真机同步，不计作真机通过。

## 登录账号后续进展

- 个人团队 `3WRUNH54B3`，忽略的 `Config/Local.xcconfig` 配置 DEVELOPMENT_TEAM；Xcode 自动创建开发证书，签名构建成功。开发配置为个人免费团队，当前 profile 到期日 2026-10-22。
- iPhone 安装成功；首次启动需用户信任开发者，完成后可启动。
- 真机首次打开资料库失败：初始化递归修改 Library/Caches/com.apple.dyld 中系统文件的属性，被 iOS 拒绝。ArchiveStore 改为仅递归处理自有 support、Documents 和 tmp/Exports；Library 和 tmp 根只创建/配置目录。
- 修复版签名构建与覆盖安装成功，实际手机屏幕进入正常聊天首页；资料库 SQLite/WAL 及收件目录已创建。ArchiveStoreTests 19/19 通过，包括只读系统缓存回归与已有文件保护/备份策略检查。
- Mac 本轮曾出现 ENOSPC，已清理本轮可重建的设备编译缓存，保留源码和 Build/Products；随后磁盘空间恢复。
- 已从手机 Watch App 确认 SE 第 2 代 GPS 44mm、watchOS 26.6，与当前 iPhone 配对。用户报告手表上找不到 App；电脑 devicectl/xcdevice 尚未发现物理手表，watch 签名 profile 尚只有 iPhone UDID。需手表端开启开发者模式并建立开发连接后重新签名、安装。
- 目前仍未进行真机音频同步，手机成功安装/运行不能替代双端同步验收。

后续日志：`signed-build-01.log`、`signed-build-02.log`、`phone-install-02.log`、`phone-launch-02.log`、`archive-regression-02.log`。首轮测试的备份排除属性会继承父目录，不能以有效值判断是否直接改写缓存；回归改为不可变系统缓存文件，验证初始化不再尝试写入缓存文件属性。

## 手表开发配对发现

最初的 devicectl/xcdevice 列表没有手表。重插 iPhone 后日志已通过蓝牙解析出真实 SE 2 的 UDID。随后 `devicectl manage pair --device <WATCH_UDID>` 成功，手表开始出现在列表中；连接从 available(paired) 逐步到 connecting/connected(no DDI)。

Device Hub 选择手表后明确显示 `Enable Developer Mode`，要求手表 Settings → Privacy & Security → Developer Mode；同时有过连接超时。用户确认此前只开启了“关联域开发”，没有执行开发者模式重启确认。当前需要用户在手表上开启真正的 Developer Mode。此前 Nearby Pairing 窗口和重复查询均没有直接解决此开关问题。

这仍不代表手表 App 已安装或真机同步完成。手机正常首页已通过 Device Hub 实图确认。手表目标首次构建因等待连接超时，日志 `watch-signed-build-01.log`；第二轮在等待 Developer Mode。

手表重启确认后，watch-details-05 已读取 Developer Mode Status: Enabled；lockState 返回 passcodeRequired=false、unlockedSinceBoot=true。Device Hub 提示已从 Enable Developer Mode/Unlock 转为 Preparing。首次实际目标签名构建等待准备超时；随后使用 devicectl device info ddiServices --auto-mount-ddis 明确准备调试镜像。同步仍未开始。

调试镜像加载与直接安装均返回 CoreDevice 12040 / kAMDReadError (0xe8000004)，未成功安装手表 App。hdiutil verify 检查 watchOS DDI 的 CRC 校验通过；随后 lockState 查询出现 RemotePairing 1001，提示基础网络/Wi-Fi不可达。Mac 已确认 Wi-Fi 连接 AI-CHJ，正请用户确认手表连接相同网络后再试。以上错误不能概括为项目构建失败，也不能直接归因于 watchOS/Xcode 版本不兼容。

用户确认手表也连接 AI-CHJ 后，重启 Mac 的 CoreDeviceService/remotepairingd 并重试，仍超时。用户要求再次尝试，`watch-ddi-state.log` 显示手表 connected(no DDI)，`watch-ddi-04.log` 停在读取调试镜像内容约 150 秒；为避免继续占用连接，主动中断此轮请求。同期 CoreDeviceService 每 10 秒记录启动 `com.apple.mobile.lockdown.remote.trusted` 失败，错误 `kAMDNoResourcesError`；`watch-lock-04.log` 也超时。Device Hub 虽显示 Unlock Your Apple Watch，但用户明确确认手表始终已解锁，因此不能据此认定用户未解锁。已切换 Device Hub 到手机以释放手表屏幕连接，随后尝试通过 devicectl 重启手表的调试服务所在设备。当前仍未安装手表 App、未进行真机同步。

`watch-reboot-01.log`：电脑发出的手表重启请求也在 30 秒后超时，未确认执行了重启。需要手表本机正常关机再开机，以尝试恢复设备侧调试服务；不要求重置或解除手机配对。

用户完成本机重启后，再次准备 DDI（`watch-ddi-05`）。新隧道成功建立，手表 RSD heartbeat 在 475ms 后回应，但镜像准备尚未完成。另发现经手机代理的开发会话出现 `kAMDPasswordProtectedError`；对 iPhone 实际查询 lockState，`phone-lock-03.json` 为 passcodeRequired=true、unlockedSinceBoot=true。已请用户解锁手机并保持有线连接，不能将此错误归为手表未解锁。

用户解锁手机后，phone-lock-04 为 passcodeRequired=false。关闭 Device Hub 并重启 Mac 调试服务，DDI 第六轮已在日志出现 Asking MobileDevice to transfer watchOS_DDI；该轮仍在 120 秒客户端上限超时。观察手表 utun10 的发送字节持续增长后，第七轮改用 600 秒上限，保留当前连接，不再中断服务；发送流量从约 3.5 MB 增至 7 MB。隧道字节计数不是镜像完成百分比，仍须以 ddiServices 成功结果为准。

第七轮调试镜像准备最终成功，`watch-ddi-07.log/json` 确认 contentIsCompatible=true、isUsable=true、platform=watchOS、buildUpdate=27A266a。隧道累计发送约 21 MB。由此不能把先前的长时间无终端进度直接判为完全卡死；手机解锁、清理残留会话及给足镜像传输时间后，已进入实际 Watch 目标签名构建（`watch-signed-build-05.log`）。

`watch-signed-build-05.log` 最终 BUILD SUCCEEDED。Watch 的新 embedded.mobileprovision 已同时包含真实 Watch 和 iPhone UDID，个人团队 profile 有效期至 2026-10-22（本次约 05:34 UTC）。随后直接安装 5.1 MB 的 MoMoAgentWatch.app（`watch-install-02`，等待上限 600 秒）。此时 devicectl 中手机和手表均为 connected，已无 no DDI 标记。

`watch-install-02.log/json` 明确安装成功，bundleID=com.momoagent.ios.watchkitapp，Watch installationURL 为 `/private/var/containers/Bundle/Application/F7A86F84-CF1A-4CE6-BD3D-F92014C5937B/MoMoAgentWatch.app/`。手机 phone-launch-03 也成功。随后电脑远程启动 Watch App 再次出现 RemotePairing 1001 隧道超时（watch-launch-01），不能据此声称 App 已启动。已请用户直接在手表打开并做 15 秒真实录音，验证手机接收；目前安装已完成，同步结果待实测。

## 真机收件与后续修复

- 用户完成手表录音，随后复查手机发现 Documents/Inbox 权限错误。该系统目录同样不能递归改写；ArchiveStore 现只递归自有 support、Documents/recordings、Documents/workspace 和 tmp/Exports。新增的 Inbox 只读文件回归先失败，再修复通过；ArchiveStoreTests 19 项（其中系统目录测试有两个参数用例）通过，日志 archive-inbox-red、archive-regression-03。
- 手机覆盖安装后，Documents/recordings 已出现两次来自真实 Watch 的录音：29.3 秒和 33.2 秒。phone-sync-01 的 SQLite/WAL 快照完整性为 ok，两条 watch 会话、两段音频，均已提交入库。抽检首段 m4a：字节数、SHA-256 与 manifest 一致，实际解码时长 29.3 秒。
- 此快照中的两个 receipt_applied 均为 0，故尚不能宣称回执往返、手表安全清理完成；源文件接收成功与完整同步闭环需要分开记录。已有一个会话的 transcript_version=2，但未核实测试句被正确识别，不计作语音识别准确性验收。
- 用户反馈首次状态错误 ArchiveStatusError 1 及一直不消失的横幅，已修复未绑定 receiver 的状态处理及横幅生命周期；状态仍严格校验库身份，不能授权清理文件。相关 phone-receive-banner-01 自动化正在运行。
- 大字号按钮横排、真实 RMS 显示映射修复见 watch-capture-interaction.md。修复版已在 watch-install-03 安装成功；最终音量校准和首次身份状态刷新变更包含在 signed-build-06，等待最后一次两端覆盖安装。
- 电脑再次远程启动 Watch 的 watch-launch-02 因 DDI metadata 读取错误失败。App 已安装不等于远程调试稳定；无需因这个失败重置手机/手表。

## 单屏与即时同步修复后的真机结果

`phone-install-07`、`watch-install-05` 已安装：手机 3 次录音共 4 个片段；`phone-sync-06` 快照中 receipt_applied=4/4，watch_status=1。说明首次身份绑定与回执往返已经接通。此前 `phone-sync-04/05` 仍为 0/4，不应混为同一验收状态。

用户随后报告手表闪退。已取回 `watch-crash-141746.ips`，EXC_BREAKPOINT/SIGTRAP，故障队列 NSOperationQueue utility；UUID 与已安装 arm64_32 debug dylib 一致，atos 定位到 WatchConnectivityTransport.transferControl 的 replyHandler 闭包。新加入的即时回调继承 MainActor，实际由 WC 后台队列调用。修复为显式 @Sendable，状态更新回调也一并处理；后台回调内仍显式 hop MainActor 更新提交状态。闪退修复前不能宣称整体真机通过。

`watch-single-screen-02` 四项、`watch-single-screen-44mm` 两项、MoMoLinkTests 22 项通过，另有真实 40 mm 验证正在进行。核查 simctl 的 deviceTypeIdentifier 后确认 MoMo-Watch-SE3-20261014 实为 44 mm，之前记录称其 40 mm 有误；40 mm 为 C5F38C36-7F45-4D99-B1A7-18A6DD89B683。

`watch-install-06` / `phone-install-08` 安装回调修复后，watch-launch-04 成功远程启动；watch-process-01 与启动 PID 483 一致，手机进程也存活，用户明确确认“能，页面正常”。随后用户再次录音并结束：`phone-sync-07` 完整性 ok，6/6 个片段 receipt_applied=1、receipt_outbox sent=1；最新状态 stopped、pendingChunkCount=0。新录音 102.6 秒，两段分别 60.0 与 42.6 秒，已从手机容器取回并验证字节数、SHA-256、实际解码帧数、连续帧覆盖与 epoch_closures.end_frame 一致，见 audio-verification.json。手机实际 UI 已显示“手表正在录音 / 状态刚刚更新”及波浪，停止状态也已入库。

最终前台观测刷新补丁 signed-build-10 编译成功，RecordingStatusTests 6/6。phone-install-09 成功；watch-install-07 因 Mac→Watch RemotePairing tunnel 1001 未安装成功，正在 watch-install-08 重试。这不改变上一版已验证的录音/回执闭环结果，但不能宣称该额外补丁已上手表。

## 本轮最终安装与验证

- watch-install-08 重试成功，安装序列 848；最终前台观测刷新补丁已上手表，watch-launch-05 远程启动成功（PID 495）。后续 phone-sync-08 仍保留 6/6 确认，资料库完整性 ok。空闲/后台状态超过新鲜度窗口仍会如实显示上次更新时间；不能将已结束或过时观察显示为实时录音。
- 用户追加自动转写要求后，signed-build-11 成功，phone-install-10 与 phone-launch-12 成功。真机转录页已查看：去掉“本机转写已就绪”、暂停/继续以及手动批次开始入口；已有 14:24 录音显示“已有转录 / 2 个音频片段”。
- phone-automatic-transcription-01：4/4 通过、无跳过，包含真实 ASR 自动完成且无控制入口/重启保留、旧全局暂停自动恢复、旧暂停批次自动恢复、错误横幅可关闭且不阻挡导航。旧依赖 UI 手动暂停的录音/播放旅程按新的自动产品行为改为自动转写与重启验证；不将此次测试称为重新覆盖“播放中首次正文到达”的时序。
- 40 mm/44 mm 单屏布局、回执先到等待身份、status 显式刷新、MoMoLink 队列及真实 102.6 秒音频/回执结果见上文各证据。本轮未提交 Git，保留当前工作树改动。
