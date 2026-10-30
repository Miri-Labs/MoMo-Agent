import SwiftUI
import UIKit

struct PhoneGmailSetupGuideView: View {
    @State private var preview: GmailGuideScreenshot?
    @State private var copiedValue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("用电脑操作 Google Cloud 更方便。创建后，只需把客户端 ID 复制到手机。下方截图可点开放大。")
                    .foregroundStyle(MoMoPalette.muted)
                step(String(localized: "1. 新建项目，启用 Gmail API"), image: "gmail-guide-api") {
                    Text("在 Google Cloud 新建一个自用项目，在 API 库搜索 Gmail API 并启用。")
                    Link("打开 Google Cloud", destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)
                }
                step(String(localized: "2. 配置授权页面"), image: "gmail-guide-audience") {
                    Text("打开 Google Auth Platform，在「品牌塑造」填写应用名称和你自己的联系邮箱。在「目标对象（受众群体）」选择「外部」，将自己的 Google 账号加入测试用户。")
                    Text("在「数据访问」中添加下面两项范围：")
                    copyValue("https://www.googleapis.com/auth/gmail.readonly", label: String(localized: "复制读取权限"))
                    copyValue("https://www.googleapis.com/auth/gmail.compose", label: String(localized: "复制草稿与发送权限"))
                }
                step(String(localized: "3. 创建 iOS 客户端"), image: "gmail-guide-client") {
                    Text("在「客户端」点「创建客户端」，应用类型选择 iOS，软件包 ID 填下方内容。App Store ID 和团队 ID 可以留空，Firebase App Check 保持未选。")
                    copyValue(Bundle.main.bundleIdentifier ?? "com.momoagent.ios", label: String(localized: "复制软件包 ID"))
                    Text("勾选「Use this client for an AI-powered agent」，然后创建。")
                }
                step(String(localized: "4. 复制 ID，回到 MoMo"), image: "gmail-guide-client-id") {
                    Text("复制你自己客户端的 ID，回到上一页粘贴，再点「保存并连接 Google」。登录同一个 Google 账号，确认邮件权限。")
                    Text("截图只作位置示例，请使用你自己的客户端 ID。无需下载或填写客户端密钥。")
                        .font(.footnote).foregroundStyle(MoMoPalette.muted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("授权期限").font(.headline)
                    Text("Google 的测试模式授权七天后到期。个人自用时，可按 Google 规则完成品牌资料，在「受众群体」发布为 In production，再重新连接；未验证提示仍可能出现。这里的发布是 Google 的授权设置。")
                    Link("查看 Google 个人自用规则", destination: URL(string: "https://support.google.com/cloud/answer/13464323?hl=zh-Hans")!)
                }
                .font(.subheadline)
            }
            .padding(24)
        }
        .phonePageSurface().navigationTitle("Gmail 配置教程").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $preview) { screenshot in
            NavigationStack {
                GmailGuideZoomView(image: screenshot.image, title: screenshot.title)
                    .background(MoMoPalette.canvas)
                    .navigationTitle("配置截图").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { preview = nil }.accessibilityIdentifier("gmail.guide.preview.done")
                    } }
            }
        }
        .accessibilityIdentifier("gmail.guide")
    }

    private func step<Content: View>(_ title: String, image: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content().font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let url = Bundle.main.url(forResource: image, withExtension: "png", subdirectory: "GmailSetup"),
               let screenshot = UIImage(contentsOfFile: url.path) {
                Button { preview = GmailGuideScreenshot(title: title, image: screenshot) } label: {
                    Image(uiImage: screenshot).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.magnifyingglass").font(.body)
                                .padding(10).background(.regularMaterial, in: Circle()).padding(8)
                        }
                }
                .buttonStyle(.plain).accessibilityLabel("放大查看：\(title)")
                .accessibilityIdentifier("gmail.guide.image.\(image)")
            }
        }
    }

    private func copyValue(_ value: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { UIPasteboard.general.string = value; copiedValue = value } label: {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel(label).accessibilityValue(copiedValue == value ? String(localized: "已复制") : "")
        }
    }
}

private struct GmailGuideScreenshot: Identifiable {
    let id = UUID()
    let title: String
    let image: UIImage
}

/// UIKit owns pinch, pan and zoom limits; the screenshot is already decoded before presentation.
private struct GmailGuideZoomView: UIViewRepresentable {
    let image: UIImage
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ZoomScrollView {
        let picture = context.coordinator.picture
        picture.image = image
        picture.isAccessibilityElement = true
        picture.accessibilityLabel = title
        picture.accessibilityIdentifier = "gmail.guide.preview.image"
        let scroll = ZoomScrollView(picture: picture)
        scroll.delegate = context.coordinator
        return scroll
    }
    func updateUIView(_ uiView: ZoomScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let picture = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    }

    final class ZoomScrollView: UIScrollView {
        private let picture: UIImageView
        private var fittedSize = CGSize.zero
        init(picture: UIImageView) {
            self.picture = picture
            super.init(frame: .zero)
            picture.sizeToFit()
            addSubview(picture)
            contentSize = picture.bounds.size
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            bouncesZoom = true
        }
        required init?(coder: NSCoder) { return nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            let imageSize = picture.bounds.size
            guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
            if fittedSize != bounds.size {
                fittedSize = bounds.size
                let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
                minimumZoomScale = fit
                maximumZoomScale = fit * 6
                zoomScale = fit
            }
            picture.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                     y: max(contentSize.height, bounds.height) / 2)
        }
    }
}
