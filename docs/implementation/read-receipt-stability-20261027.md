# 已读切换稳定性 · Beta 1.34.17

用户要求直接依据 Dots bundle 修复，停用 Ponytail。

实际 WebKit 复现：底部跟随时，已读行新插入 18px、三点区域新插入 64px，所有历史气泡在回执帧瞬间上移 82px；节点没有被替换，入场动画也没有重播。此前 20 次相同快照刷新检查没有覆盖这个状态切换。

本机 ChatGPT 26.1021.31345 的 local-conversation-turn 模块：gs 组件保持 Read 节点，只改变 opacity，initial:false；共享 tL 动画为 300ms / cubic-bezier(.19,1,.22,1)，减少动态效果时为 0。已读与 typing-status-slot 独立。我们采用同样的组件边界和透明度过渡：已读位于气泡原有间距内；本地发出消息即预留三点位置，Mac 确认后才显示，回复出现后隐藏。不复制其 1500ms 已读延时，不改变传输或模型计时。原生启动回退视图同步采用不改变布局的已读与等待位置。

新增真实 WKWebView 测试覆盖本地发送 → 回执 → canonical echo → 完整回复，以 requestAnimationFrame 记录每帧气泡位置、透明度、DOM 节点和动画，包含浅色、深色、减少动态效果与阅读历史。修复前底部模式上移 82px；修复后 0px，无节点替换、移除、淡出或入场重播。iOS 集成用例同时检查真实 RemoteTaskStore 适配后的回执前后高度与节点相同。

证据：任务 outputs/read-transition-1.34.17/{dots-bundle.json,before.log,after.log}。真机验收与构建、安装结果分别记录；WebKit 测试不能替代手机实测或额外 TTFT <500ms 验收。
