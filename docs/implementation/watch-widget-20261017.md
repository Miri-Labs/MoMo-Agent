# 手表 Widget 与录音入口

版本：1.3.0，内部构建号 17。已整合 main 的总结、附件、生活事件、语音后台处理、手表快速启动与 MoMo 动效改动。本次在独立分支 `codex/watch-widget-20261017` 实现。

## 使用与行为

在表盘复杂功能或智能叠放的添加列表中选择 MoMoAgent「随身录音」。支持圆形、矩形、行内与角落四种布局。矩形会按可用高度选择详细或紧凑布局，展示上次确认的已录时长与待确认片段数。详细布局还显示确认时间。

轻点卡片打开录音页；矩形右侧提供明确的开始、暂停或继续操作。第一版通过 URL 打开手表 App 执行。App 未运行或卡片状态已变化时，只打开录音页，由用户确认后操作。开始录音后可返回表盘，后台录音仍由原有 WatchRuntime、音频会话与编码任务负责。

冷启动恢复到 interrupted 的记录不能显示成正在录音，也不会重放旧卡片的开始或继续请求。本次没有引入无界面冷启动录音、AudioRecordingIntent 或新的后台保活方式。Apple 的 Widget 与 App 进程边界见[交互说明](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)。

## 状态与边界

- WatchRuntime 是录音状态的唯一写入者。Widget 只读 App Group 中的一个可替换 JSON 文件，不打开 SQLite、音频文件、传输队列或手机连接。
- 录音状态变化立即请求更新；持续录音由已有采样回调每 60 秒发布一次心跳。批量同步期间的队列数量变化至少间隔 10 秒发布，清空队列立即更新。不新增定时器、波形绘制或轮询。时长显示已采集值，不在 Widget 中推算增长。
- 正常采样状态以实际最后采样时间计算新鲜度。150 秒后，时间线切换到「打开确认状态」；系统决定实际刷新时机，Widget 不能作为无延迟的录音监控。记录失效时仍显示上次确认的静态时长。
- 暂停、继续与开始都附带运行时身份、录音 generation 和 session。过期操作不能修改后来恢复或开始的录音。入口不使用 toggle，重复投递不能把暂停变为继续。
- 本地状态发布先于手机连接判断。断开手机不阻止本地更新；待确认数量始终表示本地持久队列的观察值，不代表手机已接收。
- 录音就绪与历史检查分别处理。captureReady 后即可发布实际录音状态和接受入口操作，不等待全部历史恢复。待同步数量第一次成功读取前使用未知值，卡片显示「同步记录读取中」，不显示 0；历史检查失败也不覆盖仍在进行的录音状态。
- 文件写入与 Widget 刷新在独立任务中执行，编码回调不等待磁盘。发布 revision 单调递增，写入端丢弃乱序旧状态。
- 写入失败只记录 Widget 错误，不停止录音或修改录音资料。读取失败、首次使用和未知 schema 均提供打开 App 的入口，不显示伪造的正在录音。

App Group 使用 `group.com.momoagent.watch`，仅授权手表 App 与 Widget Extension。Widget 只链接 MoMoContracts，未引入录音、SQLite、ASR 或 Agent 依赖。手机、手表和扩展共用 Config/App.xcconfig 版本。

## 验证

代码检查通过：MoMoContracts 14 项、MoMoRecording 61 项、MoMoLink 28 项，共 103 项测试，包含未知队列、过期状态、旧操作、录音恢复、开放分片与持久传输边界。Release 包检查器 20 项自测通过。手表 App 与 Widget 的真实平台 Release 编译通过，覆盖 arm64、arm64_32；实际手表包的身份、版本、扩展声明、原音后台模式、入口、共享组配置、二进制与架构共 11 项静态检查通过。签名与设备运行不在本次检查范围。

测试与编译日志分别为 `code-regression-integrated.log`、`release-checker-tests-final.log`、`watch-release-version-final.log`；产物检查为 `watch-release-audit.json`。上述产物统一放在 `tmp_agent_output/20261017-watch-widget/`。

先前整合总结与附件后的手机、内嵌手表与 Widget Release 编译成功，27 项产物检查通过。该产物早于后续 main 更新，保留为打包检查记录，不作为本次安装产物。

初版执行过 10 项手表宿主测试并通过。随后用户要求只做代码验证后合并，已删除本轮临时创建的手表模拟器，不再运行设备或界面测试；该初版结果不作为最终基线的设备验收。

真机的表盘/智能叠放刷新、离开 App 后的长时间录音、系统中断和耗电仍需要脱离 Xcode 验证。本次不安装或替换用户手机与手表上的版本。
