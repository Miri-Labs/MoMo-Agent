import SwiftUI
import WatchKit
import MoMoContracts

@main
struct MoMoAgentWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtime: WatchRuntime?
    @State private var failure: String?
    @State private var widgetRequest: WatchWidgetRequest?
    @State private var widgetFailure: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime { CaptureView(runtime: runtime) }
                else if let failure {
                    VStack(spacing: 10) {
                        Text("录音资料未能打开").font(.headline)
                        Text(failure).font(.footnote)
                        Button("重试", action: initialize)
                    }
                } else { ProgressView("准备录音") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoMoPalette.canvas.ignoresSafeArea())
            .foregroundStyle(MoMoPalette.ink)
            .tint(MoMoPalette.ink)
            .preferredColorScheme(.dark)
            .task { if runtime == nil { initialize() } }
            .onOpenURL { url in
                do {
                    widgetRequest = try WatchWidgetRequest(url: url, expectedScheme: WatchWidgetStore.urlScheme)
                    if runtime == nil { initialize() }
                    performWidgetRequestIfReady()
                } catch { widgetFailure = String(localized: "这个录音入口已失效，请在这里操作。") }
            }
            .onChange(of: runtime?.captureReady) { performWidgetRequestIfReady() }
            .onChange(of: scenePhase) {
                runtime?.setPresentationActive(scenePhase == .active)
                if scenePhase == .active, let runtime { Task { await runtime.foreground() } }
                performWidgetRequestIfReady()
            }
            .alert("录音操作", isPresented: Binding(get: { widgetFailure != nil }, set: { if !$0 { widgetFailure = nil } })) {
                Button("知道了", role: .cancel) { widgetFailure = nil }
            } message: {
                Text(widgetFailure ?? "")
            }
        }
    }

    private func performWidgetRequestIfReady() {
        guard scenePhase == .active, let runtime, runtime.captureReady, let request = widgetRequest else { return }
        widgetRequest = nil
        Task { @MainActor in
            do {
                if try await runtime.performWidgetRequest(request) == false {
                    widgetFailure = String(localized: "录音状态已更新，请在这里确认并操作。")
                }
            } catch is CancellationError { }
            catch { widgetFailure = String(localized: "录音操作未完成：\(error.localizedDescription)") }
        }
    }

    private func initialize() {
        do {
            let created = try applicationDelegate.resolveRuntime()
            created.setPresentationActive(scenePhase == .active)
            runtime = created; failure = nil
        }
        catch { failure = error.localizedDescription }
    }
}
