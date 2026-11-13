import SwiftUI
import AppKit

@main
struct MoMoAgentMacApp: App {
    static let settingsID = "momo.settings"
    @Environment(\.openWindow) private var openWindow
    @State private var launchSettings = ProcessInfo.processInfo.arguments.contains("--open-settings")
    @State private var model = DesktopModel()
    @State private var companion = DesktopCompanionController()
    var body: some Scene {
        WindowGroup("MoMo Agent", id: "main") {
            Group {
                if model.setupStep == .completed { DesktopRoot(model: model) }
                else { DesktopOnboarding(model: model) }
            }.tint(MoMoPalette.ink).foregroundStyle(MoMoPalette.ink).background(MoMoPalette.canvas)
                .frame(minWidth: 820, minHeight: 620)
                .background(DesktopCompanionAttachment(model: model, companion: companion))
                .task {
                    await model.load()
                    if launchSettings {
                        launchSettings = false
                        openWindow(id: Self.settingsID)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in companion.remove(); model.shutdown() }
        }
        .defaultSize(width: 980, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { openWindow(id: Self.settingsID) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示 MoMo") { companion.show() }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        Window("设置", id: Self.settingsID) { DesktopSettings(model: model) }
            .defaultSize(width: 820, height: 560)
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
    }
}
