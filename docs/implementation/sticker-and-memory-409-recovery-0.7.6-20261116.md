# Sticker 漏产补齐与记忆页 409 冲突修复 — 0.7.6

## 背景与根因

1. **生活插画（Sticker）大量漏产：**
   - **历史失败/失效槽位永久锁死（39 张）：** `LifeIllustrations.scan()` 原逻辑仅按 `SELECT 1 FROM slots WHERE window_start<? AND window_end>?` 判断重叠，未提供重跑入口。11 月 6 日修复前遗留的 `34` 条 `state='invalid'` 记录、`3` 条因生图中途进程重启进入 `needs_review` 的记录，以及 `2` 条提炼简报阶段连续 3 次网络波动（总计仅约 6 分钟退避）即永久进入 `failed` 的记录，长期挡住对应对话重新生成。
   - **超长连续对话不封顶合并：** `_episodes()` 仅在静默间隔超过 `600s`（10 分钟）时切分，周末居家连续数小时交谈（如 11 月 14 日 `14:17..22:36` 连续 498 分钟、11 月 15 日 `08:00..13:38` 连续 338 分钟）被合并为单个超长时段，全天数千条转录仅产出 3 张插画，且需等到整段结束 10 分钟后才首次入队。
   - **手表分片延迟到达触发「前序短槽位吞噬整场长对话」：** 长对话开头的 1～5 分钟分片先到达手机完成转录并等待满 10 分钟后，会先生成一条短槽位（或因寒暄被判为 `skipped`）；后续数十分钟录音追平到达后与前序片段合并为同一 `episode`，在 `scan()` 中因与开头短槽位重叠而被整段跳过（如 11 月 12 日 `14:25..16:02` 共 96 分钟、25,296 字对话被开头 1 分钟 `skipped` 槽位吞掉）。
2. **记忆页 `Agent HTTP 409 (revision_conflict)` 报错：**
   - 手表积压录音追平过程中，同一会话更早的无声或待转录分片乱序到达手机，使会话顶层起始时间 `recorded_at` 前移（或产生亚毫秒级 `end_at` 浮点舍入差），而正文哈希与 `version` 不变；`ContextStore.sync_source()` 在同 `revision` 校验 `_core_payload` 时将顶层 `recorded_at` 变化视为元数据冲突返回 `409 revision_conflict`，固定显示在手机记忆页底部同步栏。
   - 手机本地归档处于转录重投影（`ArchiveError.projectionConflict`）期间，`PhoneContextSync.uploadSources()` 跳过重打包却仍尝试上传缓存中的旧版本快照；此外后台持续写入新记忆导致多页读取或删除记忆遇到版本变化时，Mac 与 iPhone 客户端未自动重拉最新第 1 页快照。

## 修复内容

- **自然停顿感知的超长对话切分（`Apps/MacApp/Context/life_illustrations.py`）：**
  - 新增 `_group_spans_into_episodes`：连续语音段满 `75` 分钟（`SOFT_EPISODE_SECONDS = 4500`）且出现 `>= 90s` 自然停顿，或达到 `120` 分钟硬上限（`MAX_EPISODE_SECONDS = 7200`），且该连续段剩余语音不少于 `20` 分钟（`MIN_SPLIT_REMAINDER_SECONDS = 1200`）时切分为独立场景，既支持长对话中途分段结算生图，又避免切出零碎短尾。
- **已覆盖区间扣除与历史超长单图无损补齐（`Apps/MacApp/Context/life_illustrations.py`）：**
  - `scan()` 先从原始转录片段中扣除已有槽位覆盖区间，再对未覆盖片段独立成段准入（紧邻已就绪/已删除槽位且不足 10 分钟的边界碎屑自动忽略），消除前序短片段吞噬后续延迟到达长对话的问题。
  - 对既有 `> 2.5h`（`LEGACY_MEGA_SLOT_SECONDS = 9000`）的历史 `ready` 超长插画保持原图、ID 与元数据 100% 不变，通过简报双字特征锚定其已描绘的单一子时段，其余未覆盖小时自动入队补齐。
- **生成前网络韧性与显式重跑恢复（`life_illustrations.py`, `context_server.py`, `rtc_transport.py`, `MoMoAgentClient`, `LifeIllustrationView.swift`）：**
  - 尚未发起生图请求的 `preparing` 简报提炼阶段最大重试次数提升至 `6` 次（指数退避上限 `3600s`）；`submitting` 阶段保持 `3` 次上限不变。
  - 新增 `POST /v1/life-illustrations/retry`（同步放行 LAN HTTPS 与 WebRTC 数据通道白名单）及双端设置页「重新入队生成」按钮，清理 `invalid` / `failed` / `needs_review` 未完成槽位（严格保留 `ready` / `deleted` / `skipped`）并立即唤醒后台生图线程。
- **消除记忆页 `409 revision_conflict`（`context_store.py`, `PhoneContextSync.swift`, `DesktopModel.swift`）：**
  - `ContextStore.sync_source()` 在同 `revision` 下自动合并更早的会话级 `recorded_at` 并容忍 `< 1ms` 的 `end_at` 浮点误差，同时完整保留单条转录片段时间戳篡改冲突保护。
  - `PhoneContextSync` 在归档重投影期间暂停对应会话上传，遇到 `409` 时自动强制重读本地归档补交新版本或清理已过时缓存；双端记忆列表分页与删除遇到并发 `409` 时自动重拉刷新。

## 验证与交付

- Python 回归测试：`test_life_illustrations.py` **56/56 通过**、`test_context.py` **20/20 通过**、`test_momo_memory.py` **11/11 通过**；Swift `LifeIllustrationTests` **18/18 通过**。
- 从提交 `d81d360a` 构建 **0.7.6**（内部构建号 **121**）Mac、iPhone 与 Watch Release 产物：
  - Mac 独立运行时打包签名与断网沙盒校验 `verify-mac-runtime.py` 通过，原位替换 `/Applications/MoMo Agent.app` 并验证在线，配对凭据指纹保持不变，调用 `/v1/life-illustrations/retry` 后全部 `141` 张既有成品插画完整保留，缺失与卡死时段已自动进入后台生成队列。
  - iPhone 与内嵌/独立 Watch Release 包通过 `verify-release-bundle.py --variant local-upgrade` 全部静态检查与 `codesign --verify --deep --strict` 校验（交付时物理 iPhone/Watch 未连接本机，升级包保留于 `tmp_agent_output/sticker-recovery-0.7.6-20261116/Products-Verified/` 供设备重连后直接安装）。
