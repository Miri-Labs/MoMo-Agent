# 内置 agent-desktop

MoMo 的 Mac 电脑工具使用 vercel-labs/agent-desktop v1.0.2 的原生 FFI（ABI 6）。上游：<https://github.com/vercel-labs/agent-desktop>。发行包、SHA-256、原始 C 头文件及 Apache-2.0 许可证固定在 `Vendor/AgentDesktop/`。

## 调用路径

- Hermes：`momo_computer` MCP → `ComputerGate` 注入当前工作权限 → 私有 Unix socket → Mac `DesktopControlHost` → `AgentDesktopDriver`。
- SuperAgent：Worker 内置 `computer_snapshot` / `computer_action` → 带桥接密钥的 loopback 请求 → 实时校验 ticket/assignment → 同一个桌面 lease 与原生驱动。模型不能通过工具参数指定其他工单身份。
- `computer_snapshot(app, depth)` 返回目标应用当前窗口的控件树与完整 `@snapshot:eN` 引用。保留 `complete=false`，不把截断部分解释为不存在。
- `computer_action(ref, action, ...)` 支持点击、文本替换/输入、焦点、展开/折叠、选择、勾选、滚动及组合键。默认语义操作；`headed=true` 才允许提升为前台物理输入。原有 Hermes 截图/坐标工具继续可用。
- 当前 FFI 仅支持应用的当前窗口，不提供 CLI 的指定 window ID、skeleton/root 渐进遍历、批量操作或 JEV 外部模型。遇到不可访问的自绘控件须说明实际能力限制。

## 所有权与生命周期

Mac App 加载 dylib，辅助功能权限归属于 MoMo App；控件读取无需额外录屏权限，旧截图工具仍需录屏权限。不自动弹系统授权、不修改 TCC。

所有 FFI 调用在后台线程串行执行。实际操作期间持有已有跨进程 lease 锁，禁用上游自动等待，只执行一次。用户接管、不同工作/assignment 或 epoch 变化后旧引用不可直接操作，必须重新观察；上游继续检查 stale/ambiguous ref。返回原始结果和错误 envelope，不自动重试结果不确定的操作。

SuperAgent 每次调用结束都释放占用；等待用户不会占住电脑。观察绑定到 assignment 与 epoch，其他任务或用户插入操作后失效。Hermes 保留现有工作级控制权规则。

上游临时引用数据放在应用私有 `desktop/agent-desktop` 中，目录权限 0700。每个 adapter 使用独立 UUID session，在切换工作或销毁时删除自己 session 的临时数据；不启用上游 trace 或截屏落盘。系统异常退出可能留下该私有目录中的 session 文件。

## 构建与更新

Xcode Mac target 的 `Bundle agent-desktop` 阶段通过 `Scripts/bundle-agent-desktop.py` 下载并校验固定发行包。缓存为 `Vendor/AgentDesktop/Cache`，不入 Git；后续构建复用缓存。原生库、必需 helper、许可证和出处随 App 放在 `Contents/Resources/AgentDesktop`。支持 arm64 / x86_64，通用构建用 lipo 合并；有签名身份时签名嵌入的两个 Mach-O。

用户端无需安装 Node、npm 或下载此电脑组件。更新随 App 发布；升级上游时同时更新固定版本、校验值、C 头文件并复验 ABI。SuperAgent 已提交重新编译的 `lib/index.js`，运行时指纹会识别新 bundle。

## 验证

- Mac Debug arm64 整体构建成功；实际 App bundle 内有 dylib、helper、许可证及版本记录。
- 真实发行库 smoke：ABI/结构大小、快照错误 envelope、无效引用拒绝、用户接管与未观察操作拒绝。
- Python：新增组件/双引擎控制权用例；原桌面工具、交互工作、SuperAgent gateway 回归。
- SuperAgent：TypeScript typecheck、工具注册/权限绑定/取消/原始错误保留测试、bundle 编译通过。
- `tests/tools.spec.ts` 的 “saves a settings block by name” 在改动前基线也失败（仅管理面板可修改 Source account 配置），与本接入无关；没有改动这条策略。
- 后续已使用签名 MoMo App 与独立 AppKit 窗口完成两引擎真实 GUI 填表、点击及接管验收，见 [本地 E2E 记录](agent-desktop-e2e-20261101.md)。没有覆盖已安装版本或调用外部模型。
