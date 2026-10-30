# 运行环境准备：安装路径变化误报修复

交付版本：MoMo Agent Mac 1.36.3。基线 `cf3f3360`。

## 根因

2026-10-27 用户看到高级设置中的“组件下载或安装失败”。真实 `momo-prepare.log` 只有：

```text
MoMo runtime: Agent dependencies changed; prepare a new runtime directory
```

`prepared.json` 记录旧名称目录中的 `main-1.36.0/runtime-source/Vendor/HermesAgent`，已安装 1.36.2 使用新名称目录中的 `main-1.36.2/runtime-source/Vendor/HermesAgent`。upstream commit、uv.lock、pyproject.toml、extras 和连接层 lock 的内容均一致，只有绝对路径不同。真实 `uv pip check` 检查 107 个包全部兼容。

旧代码把来源目录计入依赖等价判断，因而应用迁移、改名或升级交付目录后，`prepare` 与直接启动时的 `prepared_python` 都可能拒绝复用环境。重复点击不会改变这一条件。这次失败发生在依赖检查阶段，并非下载失败。

## 修复

- 依赖身份比较排除 `source`，继续严格比较所有依赖内容与上游版本字段。原生 Hermes 代码使用当前交付目录加载；虚拟环境原本以 `no_install_project=True` 安装，不依赖旧源码路径。
- 保留 `source` 作为来源记录。检查可用解释器和依赖内容后，准备操作原子更新该记录，无需重新下载或安装；重复准备无副作用。
- 网络依赖确实升级时仍安装并检查，失败不更新成功标记；Agent 依赖真正变化或解释器缺失仍拒绝运行，未将实际不兼容隐藏为成功。
- 界面兜底错误改为“运行环境准备失败”，避免把所有失败归为下载问题。

没有删除、重建或迁移用户的聊天、录音、记忆、配置或配对目录。

## 验证

1. `uv run --no-project python -m unittest discover -s Tests/AgentRuntime -p test_runtime.py -v`：17 项通过。覆盖旧路径不存在、重复准备、用户文件保持不变、真实依赖变化仍拒绝、路径变化与网络升级并存、失败后重试及缺失解释器。
2. `uv pip check --python "$HOME/Library/Application Support/MoMoAgent/Agent/runtime/venv/bin/python"`：107 个已安装包兼容。
3. 从冻结的 1.36.3 交付源码对真实环境执行准备两次：均直接 ready，无下载、无依赖变更；核对账号、配置与配对凭据内容保持不变。
4. Mac Release 构建成功。实际安装包版本 1.36.3、Bundle ID `com.momoagent.mac.dev`；`codesign --verify --deep --strict` 通过，designated requirement 与上一份有 Apple 签名的 1.36.2 交付一致。安装前发现 Applications 中为临时 ad-hoc Debug 包，将该包保留供回滚后换回稳定签名。
5. 在已安装 App 的“设置 → 高级”实际点击“准备环境”：日志为 `MOMO_PREPARE ready`，界面未出现错误；本地管理接口确认 Agent online、Tailscale connected。

证据：`MoMo-Agent-deliveries/main-1.36.3/validation/prepare-result.json`、`runtime-tests.log`、`mac-build.log`。日志与记录不包含凭据。

此修复只解决运行环境准备。远程桌面的编码视频 / WebRTC 改造另行实施，不能用环境准备成功替代画面与接管验收。
