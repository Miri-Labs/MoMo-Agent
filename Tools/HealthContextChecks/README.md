# 健康摘要回归

从仓库根目录执行：

```bash
bash Tests/Support/check-health-context.sh tmp_agent_output/health-context-check
```

该入口复用真实 `MoMoAgent` 和 iPhone `PhoneHealthContext.swift` 源码，运行健康摘要控制器及原生查询生命周期的故障测试，再用 iOS 18 部署目标编译原生读取层并检查设置页面。测试覆盖升级授权、部分成功、空数据、锁屏错误、超时、取消、迟到回调和旧摘要兼容。

故障测试使用注入的 HealthKit 边界，在 Mac 上运行，不启动模拟器。它们不代表用户手机的真实授权与健康数据已验收。真机应检查仅开放部分类型、补充心率授权、解锁后重试及退出页面后的查询取消。

`Sources` 和控制器测试通过相对软链接引用业务源码，避免复制实现。验证包只使用仓库内的本地依赖，不下载语音模型。
