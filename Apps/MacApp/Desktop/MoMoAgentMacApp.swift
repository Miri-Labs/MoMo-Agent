import SwiftUI
import AppKit

@main
struct MoMoAgentMacApp: App {
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
                .task { await model.load() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in companion.remove(); model.shutdown() }
        }
        .defaultSize(width: 980, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("显示 MoMo") { companion.show() }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        Settings { DesktopSettings(model: model) }
            .defaultSize(width: 680, height: 440)
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
