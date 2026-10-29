# MoMo 眼部表情接入

> 历史记录：下文保存 1.7.0 的初版实现与验证。用户随后明确要求按原理和 MoMo 性格原创设计；当前代码已移除其中的 GrokBot 表情数据与提取器，新的实现见 [1.7.1 场景表情](momo-personality-expressions-20261018.md)。

日期：2026-10-18。源码版本：1.7.0。用户要求将 `ArvinYin1/grokbot-animation-anatomy` 的表情放入 MoMoAgent。

保留现有 MoMo 的身体、双波峰、黑白配色、首页到聊天顶部的同一角色、手表状态小标与原品牌思考动画。接入上游全部九种眼部表情：neutral、happy、surprised、inspecting、sad、sleepy、squinted、calm、confused。没有替换为 Grok 的球形角色或引入其品牌形状；本次也不移植 53 种产品/装饰状态。

## 接入方式

固定上游提交 `d3ba1d901eb8d1242f1bd763b314afb1fae2f55a`，保存未经修改的播放器、recipes、原始来源声明及 SHA-256。构建时运行其 SDF 轮廓提取函数，将每只眼睛按一致方向采样为 64 个顶点，并适配 MoMo 原有的眼部尺寸。App 只加载原有 `momoagent-avatar.js`；新增数据内嵌其中，没有运行时 fetch、第二套播放器或新依赖。

在现有头像构建器中对固定的生成引擎实施单次匹配补丁，让自定义轮廓继续走原有头部表面投影、朝向、位置、眼睑和裁剪。表情与转头分别控制；280ms 过渡共用既有帧时钟，重复状态不重启，中途切换从已显示的轮廓继续。正常模式最多 30 次几何绘制/秒，低电量最多 15 次；停用、隐藏、后台及减少动态效果下不启动表情时钟，静态状态变化仍会绘制一次。

原生使用 `PersonalAgentExpression`，通过现有 `Appearance` 参数传给同一个 WKWebView。聊天映射如下：

| 场景 | 表情 |
| --- | --- |
| 空首页与平常待机 | neutral，沿用首页转头 |
| 编辑输入、恢复历史或停止回复 | calm |
| 等待回复、思考与继续下一模型轮次 | inspecting，复用既有 thinking 动作 |
| 当前回复含 pending/running 工具 | squinted，复用 thinking 动作 |
| 正在输出正文 | neutral |
| 回复完成 | happy |
| 请求失败或上下文整理失败 | confused |
| 点击招呼 | happy，第三次为 surprised；动作结束回到当前实际状态 |

工具执行可以位于已结束模型输出的消息中，因此不以消息必须为 streaming 作为执行中的前提。只检查当前尾部消息，避免旧回复的工具影响新一轮。首次体验的聆听、回应与完成阶段复用同一组件，并显示 calm / inspecting / happy。减少动态效果时，点击只显示静态 happy。

## 验证

- `node Vendor/BibleStrongAvatar/test.mjs`：15 项通过，包含九种不同轮廓、身体不变、静态无调度、连续中断、重复状态、眨眼、30/15 fps、网页点击恢复及隐藏/销毁清理。
- `uv run Tools/ChatRenderer/prepare-vendor.py`：资源与生成产物一致性通过，核对原头像的 24 份源文件及 GrokBot 的 3 份源文件哈希，保留品牌资源校验。
- 聊天渲染核心 19 项及品牌动画测试通过；`git diff --check` 通过。
- 对九种表情的 81 个有向组合，各检查 5 个过渡采样、两只眼睛，共 810 份投影轮廓，未发现自相交。
- 从实际运行时输出 SVG，并以 CairoSVG 光栅化，人工核读[九种表情预览](evidence/2026-10-18-momo-expressions/expressions.png)。这是几何渲染预览，不是浏览器、WKWebView 或模拟器截图。
- 新增原生 WebKit 集成用例，覆盖九种原生参数传递、同一 WKWebView、停用状态与深色眼部颜色。当前 Linux 环境没有 Swift/Xcode，未执行该用例、原生编译、模拟器或设备验证，也没有生成可安装 App；1.7.0 为本次源码版本。

上游 README 将仓库标为 MIT，同时说明动画数据取自原应用、相关设计与数据版权归原所有者且材料用于学习研究。完整声明保存在 `Vendor/GrokBotExpressions`，并将 `grok-expressions.NOTICE.txt` 随 App 资源打包；未将这些数据或既有 AGPL 头像引擎重新许可。
