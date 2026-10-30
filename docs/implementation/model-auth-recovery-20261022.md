# 模型认证恢复（1.24.2）

旧实现将浏览器认证写入全局 busy，等待进程 stdout 关闭后才更新界面；浏览器未回跳时返回被禁用，取消也依赖进程退出。现在认证使用独立会话与任务，授权链接先通过 JSON 行事件交给原生界面。返回立即释放界面、取消旧任务，迟到结果不得覆盖重试；退出或离开认证页同样取消。页面从当前认证与账号状态直接推导，快速完成时不依赖界面是否观察到短暂的等待状态。

参照内置 Hermes 的 `web/src/components/OAuthLoginModal.tsx`：显示验证码、复制与重新打开入口、有效期、重试及返回。Codex 默认复用 Hermes 设备码请求、轮询、交换与保存，可切换到已有 PKCE 浏览器登录；后者只增加发布 URL 的可选回调，安全校验仍由 Hermes 负责，补丁记入 UPSTREAM.json。设备码可能需要在 ChatGPT 安全设置允许，见 [官方认证文档](https://learn.chatgpt.com/docs/auth#preferred-device-code-authentication-beta)。Claude 保留官方 Claude Code 登录，只向界面发布允许来源的授权 URL。

单次认证限时五分钟，Swift 父进程看门狗与 Python 超时共同收尾。取消先发 SIGTERM，卡住的父进程两秒后强制结束；Claude 子进程组一秒后仍未退出则强制结束。状态检查与模型验证也有等待上限。认证 URL 只允许对应官方 HTTPS 来源与授权路径；凭据不会通过进度事件或界面日志传递。

验证：15 项 Python 合约测试通过，包含真实 Hermes 浏览器 helper 的无网络 PKCE 链路。Swift 6 原生进程探针验证流式验证码、非阻塞等待、即时取消、迟到结果隔离、硬超时、URL 限制、异常结果及强制进程清理。隔离的实际 Mac 窗口验证超时重试、验证码与有效期显示、等待时返回、取消后切换 API，以及已有登录瞬时成功时直接进入模型选择。Mac Beta 构建通过，局部 UI 扫描无 high 项；真实账号授权未重复完成。
