# 原文读取改为 token 预算

日期：2026-10-17。基线 `1240b6927ee10865bd501afc0f83588da213e51a`。用户指出上一版不应让 Agent 按 KB 选择读取量；沿用此前优化并推送 main 的授权。

## 依据与修正

Codex 对 Agent 暴露 `max_output_tokens`，默认 10,000；[底层计数](https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/codex-rs/utils/string/src/truncate.rs) 使用 UTF-8 字节 / 4 的近似，同时另有 1 MiB 输出收集保护。Claude 公开 SDK 提供行范围、`allow_large` 和 `truncatedByTokenCap`，详见[一手调研](../research/transcript-reading-2026-10-17.md)。token 接口不等于已经具备每种模型的精确 tokenizer。

上一版还有一处计算问题：把剩余 token 数直接当作返回字节额度，且下次请求会用序列化字节数覆盖上次 provider 用量；这会过度限制读取。此次同时修复接口和计量，保留完整 JSON、Unicode 无损续读、固定转录版本与来源失效规则。

## 当前契约

- Agent 参数 `maxOutputTokens`：最小 2,048、默认 32,768、最大 262,144 tokens，默认 200 段、最多 1,000 段。实际额度取请求值与剩余上下文中较小者，预留配置的回答上限及 framing 空间。
- 返回 `requestedMaxOutputTokens`、`maxOutputTokens`、`estimatedOutputTokens`、`tokenCountIsEstimate: true`；不再暴露 `maxBytes` / `requestedMaxBytes`。`token_limit` 替代 `byte_limit`；`context_budget` / `passage_limit`、精确续读位置与完整结束标记继续保留。
- 估算计入完整序列化 JSON，包含引用、时间、转义、说明与计数自身。内部以整数四分之一 token 单位累加，ASCII 每字符 1 单位，非 ASCII 每 Unicode scalar 8 单位，最终向上取整；相同字节长度的中英文会占不同估算额度。**这是模型无关的文本近似，不是任何 provider 的精确 token 数或多模态上下文保证。** 暂不新增 tokenizer 依赖；若 provider 将来提供本地计数能力，可替换此估算。
- 上下文优先采用最近有效的模型用量（含缓存与输出），仅估算其后新增内容。压缩后的新前缀会令旧用量失效，隐私过滤后的消息仍是预算依据。未得到用量时才估算序列化消息；每个工具结果另留少量 framing 空间。
- 底层 Pi 保留 1 MiB 传输保护，业务页先按 token 预算完成分页并复核。当前估算的每四分之一 token 单位至少覆盖一个 UTF-8 字节，因此最高 token 页也不超过该传输上限，不再被更小的通用输出额度二次截坏。
- 累计 4,096 来源限制不变，仍显式报告耗尽；扩大单页不能绕过该限制。

## 验证

新增验证关注相同字节长度的中英文占不同 token 预算、最大 token 页超过旧字节上限仍返回完整 JSON、最小/默认/最大预算下 Unicode 与转义的 UTF-8 无损重组，以及跨请求保留 provider 用量、新压缩前缀使旧用量失效。真实 Pi harness 继续验证完整页确实到达模型，来源重启/修订失效仍有效。离线 corpus 检查器的分页估计同步改用 token。

最终源码 `d1b7d5d3434a2fa74af2fec15e26e4b9e0269a60` 的 [Xcode 27 原生检查](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39020787869)通过：151 项 Archive 测试、19 项 Agent 相关测试；大页测试分别跑中文和英文两种输入，英文结果确实超过旧 256 KiB 上限并以完整 JSON 到达脚本 provider。2,048 / 32,768 / 262,144 tokens 三种额度的 UTF-8 无损重组与完整 JSON 断言均通过。

离线检查器 17 项自检通过，32 条冻结 JSON 场景结构检查通过，冻结哈希不变；不表示执行了模型质量评估。先前 [run 39020684643](https://github.com/xilanhua12138/MoMoAgent/actions/runs/39020684643) 因新增文件遗漏 `MoMoContracts` import 编译失败，补齐后得到上述成功结果。无 native 测试失败遗留在本次检查范围内。

工作区无 Swift/Xcode，原生检查使用现有 GitHub Actions；没有扩大运行至已知失败的完整 Agent 矩阵，既有失败及第一版证据见[先前记录](transcript-reading-20261017.md)。本次未生成或安装 App，继续属于同一 1.3.4 交付版本的代码迭代。
