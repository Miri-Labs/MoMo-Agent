import SwiftUI

struct TailnetHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("TailscaleBrand").resizable().scaledToFit().frame(width: 121, height: 22)
                .accessibilityLabel("Tailscale").accessibilityAddTraits(.isHeader)
            Text("手机与 Mac 在 MoMo Agent 内登录同一账号。无需另装 App 或开启系统 VPN。")
            Text("Mac 保持在线即可连接，锁屏不影响，睡眠时不可用。")
            Link("Tailscale 帮助", destination: URL(string: "https://tailscale.com/kb")!)
        }.font(.system(size: 13)).padding(20).frame(maxWidth: 300)
    }
}
