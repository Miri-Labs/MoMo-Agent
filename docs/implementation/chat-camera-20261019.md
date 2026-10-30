# 聊天拍照附件

聊天输入框的加号菜单增加“拍照”。使用系统相机完成拍摄、重拍和确认，确认后将照片添加到当前草稿，沿用现有预览、移除、草稿保存和发送流程。版本为 `1.12.0`。

## 行为与边界

- 只在用户点击“拍照”时请求相机授权。拒绝授权后可打开系统设置；相机不可用或受系统限制时显示对应提示。
- 取消拍摄不增加附件，重复的系统完成回调不会重复添加照片。
- 照片在后台缩至最长边 1536 像素，再进入已有 JPEG 与缩略图处理流程。照片方向由绘制过程归正，输出沿用 1 MB 上限。
- 拍照继续遵守最多 4 个附件的限制。照片处理期间禁用发送，处理完成后才允许发送。
- 拍摄或处理期间如果会话改变，不把照片添加到另一个会话。
- `project.yml` 与生成的手机 Info.plist 都包含 `NSCameraUsageDescription`。权限说明告知用户，点击发送后照片会发送给其选用的 AI 服务。

实现使用 [UIImagePickerController](https://developer.apple.com/documentation/uikit/uiimagepickercontroller) 的相机模式，权限键见 [NSCameraUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription)。API 和并发标注同时按本机 Xcode SDK 核对。

## 验证

- 新增三项 iPhone 集成回归，覆盖照片尺寸与方向、取消及重复回调、缺失图片结果。通用 iOS 目标的 `build-for-testing` 已通过，用例已编译，尚未执行。
- Release 构建通过；`verify-release-bundle.py` 静态校验通过。另行核对了实际包中的相机权限说明及 `1.12.0` 版本，与源码配置一致。构建关闭签名，只用于代码与包内容验证。
- 真机拍摄、系统授权弹窗及发送链路需要在安装后验证。本轮不安装设备或启动模拟器。
