import SwiftUI
import UIKit

@MainActor final class BenchStatus: ObservableObject {
    @Published var text = "idle: launch with --bench-model KEY --bench-task ascend|real --bench-phase fg|bg --bench-run NAME"
}

@main
struct ASRBenchApp: App {
    @StateObject private var status = BenchStatus()
    private let state = AppStateFlag()
    private let keeper = BackgroundKeeper()

    var body: some Scene {
        WindowGroup {
            Text(status.text)
                .font(.system(.body, design: .monospaced))
                .padding()
                .onAppear(perform: start)
        }
    }

    private func start() {
        let state = state
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in state.inBackground = true }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in state.inBackground = false }
        guard let arguments = BenchArguments(ProcessInfo.processInfo.arguments) else { return }
        if arguments.phase == "bg" {
            do { try keeper.start() } catch { status.text = "FAILED background audio: \(error)"; return }
        }
        let status = status
        let job = BenchJob(arguments: arguments, state: state) { text in
            Task { @MainActor in status.text = text }
        }
        // Same QoS as the app's speech queue (.default); a main-thread-sized stack for native decoders.
        let thread = Thread { job.run() }
        thread.stackSize = 8 << 20
        thread.qualityOfService = .default
        thread.start()
    }
}
