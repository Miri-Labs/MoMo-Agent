import SwiftUI

@main struct ProbeApp: App {
    @State private var result = "Testing two embedded nodes…"
    var body: some Scene {
        WindowGroup {
            Text(result).padding().task {
                let root = URL.documentsDirectory.appendingPathComponent("probe-state")
                do {
                    let args = ProcessInfo.processInfo.arguments
                    guard let index = args.firstIndex(of: "--control"), args.indices.contains(index + 1) else { return }
                    try await Probe.run(controlURL: args[index + 1], root: root)
                    result = "PASS: two nodes, SSE, persisted identity, cursor resume"
                } catch { result = "FAIL: \(error)" }
                try? Data(result.utf8).write(to: URL.documentsDirectory.appendingPathComponent("result.txt"))
            }
        }
    }
}
