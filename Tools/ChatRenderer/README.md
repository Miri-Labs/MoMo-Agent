# 离线聊天渲染资源

`Apps/iPhoneApp/Features/Assistant/Rendering/Web` 是独立前端，只接收 `ChatRenderSnapshot`，不依赖 Agent SDK。`chat-core.js` 包含可独立测试的展示规则；`chat.js` 负责 DOM、Markdown、安全处理和交互；原生桥接只在 `ChatRendererView.swift`。

固定依赖：marked 18.1.1（MIT）、DOMPurify 3.4.17（Apache-2.0 / MPL-2.0）、KaTeX 0.19.0（MIT）、remend 1.4.0（Apache-2.0）、highlight.js CDN assets 11.12.0（BSD-3-Clause）。KaTeX 只保留 WOFF2 字体；其他依赖只保留实际使用的浏览器文件和许可证。remend 的唯一修改是将 ESM 导出尾部替换为 `globalThis.remend`，方便在 WKWebView 的本地文件页面中使用普通脚本加载。没有执行或嵌入 Claude 生产脚本。

```sh
# 普通验证不联网。
uv run Tools/ChatRenderer/prepare-vendor.py
node Tests/Support/chat-renderer-core.test.cjs
node Tests/Support/brand-motion.test.cjs

# 只有更新或重建时下载；检查固定 tarball SHA-512，输出固定文件清单与 SHA-256。
uv run Tools/ChatRenderer/prepare-vendor.py --download
```

更改 vendor 版本时，同时更新固定版本和 tarball 完整性值，保留许可证，重新运行校验与 WebKit 宿主测试。不要以 CDN 链接替换本地资源。字体、脚本、样式全部从 App 资源加载，运行时没有依赖下载。

`prepare-vendor.py` 同时调用 Avatar 的独立源码生成检查；目录只允许 Markdown 清单、清单自身与经过检查的 Avatar 运行时及完整许可证，不忽略其他新增文件。

MoMo 的八种[场景表情](../../docs/implementation/momo-expressive-motion-20261018.md)由原创尺寸、弯曲、倾斜与视线参数实时生成，借鉴程序化形变与状态过渡的原理，不读取参考项目的表情数据。眼型在顶部尺寸下区分睁大、一眯一睁、专注横眼、大弯眼与单眼眨，身体在 SVG 内配合歪头、点头、轻弹和压缩伸展。原生传递 `expression`，不重建 WKWebView；首页与聊天顶部继续使用同一个 MoMo。过渡、完成后的自动收回共用既有 30/15 fps 时钟，静态或减少动态效果下直接显示当前表情。完成历史不会触发新的庆祝，忙碌时点击使用较小的点头回应。

```sh
xcodebuild test-without-building -project MoMoAgent.xcodeproj -scheme MoMoAgent \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -derivedDataPath DERIVED_DATA \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:MoMoAgentIntegrationTests/ChatRendererTests \
  -resultBundlePath NEW_RESULT_PATH CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

先用当前源码 `build-for-testing`，不要用旧 xctestrun 验证修改后的前端资源或测试。

## 鹅卵石思考动画

`pebble-source.mjs` 保存原品牌的三块轮廓、圆润体积、灯光和连续轨迹。绕 X / Y 轴翻面时同时前后换位，每 5.8 秒组合回图标并继续下一轮。位置和速度在循环首尾相同，没有分段停顿。`brand-pebbles.webp` 是 174 帧、30 fps 的无损图集，单帧 64×56，聊天中显示为 32×28 点。图集约 150 KiB，解码像素约 2.4 MiB。

App 只运行本地 `brand-motion.js`，不加载 Three 或联网。先显示小尺寸的组合静帧，再异步载入图集；消息渲染不等待动画。等待、思考和工具执行复用一个 Canvas 和一个时钟。收到正文或停止回复后复位；后台、离屏和原生视图拆除时暂停；减少动态效果时只加载静帧，不请求图集。原始图标、顶部 MoMo 角色和文字 shimmer 保留。

为控制手机消耗，未采用预览中的 60 fps / 3 倍分辨率：实际图集像素约少 78%，绘制上限减半；高刷新率屏幕上也跳过相同帧，不逐帧修改 DOM。这里的内存值是图集尺寸乘以四通道估算，不是进程总内存或实测耗电。

普通资源校验包含图集及其源码 SHA-256。重建时使用 Three 0.160.0 的 MIT 版本，仅用于生成素材：

```sh
# 在本次任务独立的 tmp_agent_output 子目录中保存生成文件。
mkdir -p tmp_agent_output/pebble-capture
cp Tools/ChatRenderer/capture-pebbles.html tmp_agent_output/pebble-capture/index.html
curl -fL https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.min.js \
  -o tmp_agent_output/pebble-capture/three.module.min.js
shasum -a 256 tmp_agent_output/pebble-capture/three.module.min.js
# 必须为 3e690ac7d180b0aadf0891bea39eec643e29e2d3e75c99b18689518665f69ba6。
uv run python -m http.server 8916 --bind 127.0.0.1
```

用 ego-browser 在同一任务空间中打开 `http://127.0.0.1:8916/tmp_agent_output/pebble-capture/`。等待 `window.renderPebbleFrame` 可用后，依次调用 `window.renderPebbleFrame(index / 174 * Math.PI * 2)`，索引为 0…173。它返回 PNG data URL；在 Node 侧解码并保存为 `frames/000.png`…`frames/173.png`。每批最多 20 帧，避免单次浏览器调用过长。然后打包：

```sh
uv run --with pillow Tools/ChatRenderer/prepare-pebbles.py \
  --frames tmp_agent_output/pebble-capture/frames
uv run Tools/ChatRenderer/prepare-vendor.py
node Tests/Support/brand-motion.test.cjs
```

重建后必须用 WebKit 宿主测试确认实际像素变化、状态切换和暂停行为。生成器只用于离线素材，不加入 App 的 Web 目录。
