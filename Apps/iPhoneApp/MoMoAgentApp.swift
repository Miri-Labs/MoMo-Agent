import SwiftUI

@main
struct MoMoAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime = appDelegate.bootstrap.runtime { PhoneRootView(runtime: runtime) }
                else if let startupFailure = appDelegate.bootstrap.failure {
                    ContentUnavailableView {
                        Label("暂时无法打开资料库", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(startupFailure) } actions: {
                        Button("重试", action: appDelegate.bootstrap.initialize)
                    }
                } else { ProgressView("正在打开本机资料") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .phonePageSurface()
            .task { appDelegate.bootstrap.initialize() }
            .onChange(of: scenePhase) {
                if scenePhase == .inactive, let runtime = appDelegate.bootstrap.runtime { runtime.leavingForeground() }
                if scenePhase == .active {
                    appDelegate.bootstrap.initialize()
                    if let runtime = appDelegate.bootstrap.runtime { Task { await runtime.foreground() } }
                }
                if scenePhase == .background, let runtime = appDelegate.bootstrap.runtime {
                    runtime.leavingForeground()
                    Task { await runtime.background() }
                }
            }
        }
    }
}
