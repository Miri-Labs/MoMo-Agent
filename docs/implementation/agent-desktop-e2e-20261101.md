# agent-desktop 本地 GUI E2E 验收

2026-11-01，原生应用代码 `822377e2`，Mac 版 `0.0.1`。Apple Development 签名的真实 MoMo App 在独立数据目录运行，辅助功能和录屏权限检查均为 true；没有修改 TCC、覆盖已安装 App、读取个人应用内容或调用外部模型。

结果：[机器可读报告](evidence/agent-desktop-e2e-20261101/report.json)。测试操作真实 AppKit 窗口，独立窗口进程记录的表单状态与工具重新读取的界面一致。

| 路径 / 场景 | 实际结果 |
| --- | --- |
| Hermes ComputerGate → MCP stdio → 私有 Unix IPC → 签名 Mac App → 原生 FFI | 读取真实控件树，填入中文，勾选复选框，点击保存；窗口显示与独立状态文件一致 |
| Hermes 用户接管 | 挂起待执行点击；接管期间保存次数不变；交还后旧点击返回 desktop_changed，未重放；新快照后只执行一次 |
| SuperAgent TypeScript 内置工具 → 带密钥 HTTP 网关 → 工单读取 HTTP → 同一原生驱动 | 再次填写中文并保存；重新读取界面确认结果 |
| SuperAgent 无凭据、用户接管、工单结束 | 分别返回 403 / 409 / 409，未额外操作表单 |
| 最终独立状态 | 保存次数严格等于 3，勾选为 true，内容为「SuperAgent 原生电脑工具 E2E 通过」 |

这不是大模型自主规划验收：Hermes 使用真实 admission/claim 与 ComputerGate，SuperAgent 的 ticket/assignment 状态由本地 HTTP fixture 提供；工具本体、MCP、网关权限检查、原生 IPC、FFI、OS 辅助功能和 AppKit 控件均为实际执行。没有把其他应用或自绘控件的兼容性视为已验收。

## 重跑

1. 构建并签名当前 Mac target，确保该 MoMo App 已有辅助功能权限。此测试不会申请、重置或绕过权限，也不需要安装覆盖。
2. 在 `Vendor/SuperAgent` 运行 `pnpm install --frozen-lockfile`。
3. 设置 `MOMO_RUNTIME_PYTHON` 为已准备好的 MoMo runtime Python 路径，`MOMO_TEST_APP` 为已签名的测试 App 路径，然后运行：

```sh
uv run --no-project --python "$MOMO_RUNTIME_PYTHON" python Tests/Support/run-agent-desktop-e2e.py \
  --app "$MOMO_TEST_APP" \
  --output tmp_agent_output/desktop-e2e
```

脚本自动编译专用 AppKit 测试窗口、初始化隔离的本地数据（18465–18468 端口）、运行真实工具链并退出自己的测试进程。输出包括 `report.json`、控件快照、独立表单状态和诊断日志。拒绝复用非测试目录或仍在运行的测试实例。Python 环境仅通过符号链接复用，不写入现有用户资料。

`Vendor/SuperAgent/tests/momo-computer-e2e.spec.ts` 默认跳过；只有上述 runner 设置本地测试环境和目录标记时才执行 GUI 操作。TypeScript typecheck 通过。

本次验收后已停止全部专用测试进程，保留上述小型报告并清理临时 App、隔离数据、构建和依赖缓存；现有 `/Applications/MoMo Agent.app` 保持原样。
