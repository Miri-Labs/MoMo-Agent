import SwiftUI
import VisionKit

struct PhonePairingControls: View {
    @Bindable var agent: PhoneRemoteAgent
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var retry = 0
    private var pairing: PhonePairing { agent.pairing }
    private var activityID: String { "\(pairing.pending?.invitation.invitationID.uuidString ?? "")-\(scenePhase)-\(retry)" }

    var body: some View {
        VStack(spacing: 20) {
            if pairing.pending != nil {
                if let receipt = pairing.receipt {
                    let ended = ["rejected", "expired", "revoked"].contains(receipt.state)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(ended ? "这次配对已结束" : "核对两端的数字").phoneText(.section)
                        Text(receipt.code).font(.largeTitle.monospacedDigit()).textSelection(.enabled)
                            .accessibilityIdentifier("remote.pairCode")
                        Text(receipt.state == "approved" ? (pairing.failure == nil ? "Mac 已允许，正在验证连接…" : "连接验证未完成，请重试。") : ended ? "请在 Mac 刷新二维码后重新扫描。" : "确认 Mac 显示相同数字，再在 Mac 点击允许连接。")
                            .phoneText(.body).foregroundStyle(MoMoPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 24))
                    if ended { Button("重新扫码") { clearPairing(); scanning = true }.buttonStyle(ClientPrimaryButton()) }
                    else if pairing.failure != nil {
                        Button("重试连接") { retry += 1 }.buttonStyle(ClientPrimaryButton())
                            .accessibilityIdentifier("remote.retryPairing")
                    }
                } else {
                    Button(pairing.failure == nil ? "正在联系 Mac" : "重试连接") { retry += 1 }
                        .buttonStyle(ClientPrimaryButton(isLoading: pairing.failure == nil))
                        .disabled(pairing.failure == nil).accessibilityIdentifier("remote.retryPairing")
                }
                if pairing.failure != nil, pairing.receipt.map({ !["rejected", "expired", "revoked"].contains($0.state) }) ?? true {
                    Button("重新扫码") { clearPairing(); scanning = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(MoMoPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                Button("扫描配对码", systemImage: "qrcode.viewfinder") { scanning = true }
                    .buttonStyle(ClientPrimaryButton()).accessibilityIdentifier("remote.scanMac")
            }
            if let failure = pairing.failure {
                Text(failure).foregroundStyle(MoMoPalette.failure).font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("remote.pairingFailure")
                if pairing.pending?.invitation.network == "tailscale" {
                    Text("若无法联系 Mac，请确认两端 MoMo Agent 已登录同一 Tailscale 网络，且 Mac 未进入睡眠。")
                        .foregroundStyle(.secondary).font(.footnote)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                Group {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        PairingCamera { text in scanning = false; pairing.scan(text) }
                    } else {
                        ContentUnavailableView("相机暂时不可用", systemImage: "camera", description: Text("请在系统设置允许相机访问。"))
                    }
                }.navigationTitle("扫描配对码")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } } }
            }
        }
        .task(id: activityID) {
            if scenePhase == .active { await pairing.resume(agent: agent, name: UIDevice.current.name) }
        }
    }

    private func clearPairing() {
        do { try pairing.clear() } catch { pairing.failure = error.localizedDescription }
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { context.coordinator.report(error, in: controller) }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        private var finished = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished, let item = addedItems.first, case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { return }
            finished = true; dataScanner.stopScanning(); scanned(text)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { report(error, in: dataScanner) }
        func report(_ error: Error, in controller: UIViewController) {
            let alert = UIAlertController(title: String(localized: "无法使用相机"), message: String(localized: "请在系统设置允许相机访问。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "知道了"), style: .default))
            controller.present(alert, animated: true)
        }
    }
}
