# MoMo Agent 真机更新 · 2026-10-27

用户要求将已改名的产品重新安装到手机、手表和 Mac。交付版本 **1.35.2**，内部构建号 149；实际构建源码为 `80906ee53811b93d4fcf15c3b79e6a5d9250a2b4`，包含 main 的品牌实现 `5ec45761`。

## 安装结果

- iPhone：覆盖更新 `com.momoagent.ios`。设备清单读回名称 **MoMo Agent**、1.35.2；首次启动被锁屏拒绝，用户解锁后启动成功，并再次查到运行进程。
- Watch：复用已恢复的开发连接，先串行确认 DDI compatible / usable。确认 Watch 与 Widget 描述文件包含真实手表后直接覆盖安装；设备清单读回 **MoMo Agent**、1.35.2，启动成功。
- Mac：安装为 `/Applications/MoMo Agent.app`，界面实测显示新名称、M 图标及“MoMo 正在运行”。沿用 `com.momoagent.mac.dev` 和原 Apple 开发签名身份；旧名称应用移入废纸篓。
- 数据与连接：没有卸载手机/手表或重建配对。手机诊断刷新后资料库身份保持一致；Mac 连接配置、凭据和聊天数据库在替换时保持不变，内嵌 Tailscale 为 connected，Agent 在线，并收到已配对设备的近期请求。

## 本轮验证与边界

手机 Release（含 Watch / Widget）和 Mac Release 均构建成功。实际包名称、版本、原 Bundle ID、设备签名范围、描述文件有效期及 deep/strict 签名检查通过；`verify-release-bundle.py` 最终报告为 passed。首次审计路径曾被失败报告占用，改用新的 `release-bundle-verified.json` 后执行成功，没有绕过检查。

Mac 使用固定提交的运行源码快照；依赖指纹除源码位置外完全一致，`uv pip check` 确认 107 个已装包兼容后复用原环境。旧进程退出、取得运行锁后才更新源码位置；没有下载新运行依赖或改用户模型配置。

本轮没有新增或重跑业务功能测试，也没有将安装、启动与近期请求当作跨网接管、后台消息、推送或录音能耗的完整验收。个人开发团队的本地手机包继续禁用 APNs；通知服务仍未配置。

安装包与运行快照保存在本机 `MoMoAgent-deliveries/main-1.35.2/`；原标识与数据路径有意保留，品牌改名不更换应用身份。本轮构建、签名、安装、启动、设备版本及资料基线证据保存在聊天工作目录 `outputs/momo-agent-install-20261027/`，不将设备标识、原始诊断或凭据提交到 Git。以后设备连接失败先看 [连接恢复指南](../../install.md#connection-checklist)。
