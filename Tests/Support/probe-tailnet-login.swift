import Foundation

/// Optional live smoke test: compile with the real TailscaleKit, EmbeddedTailnet,
/// TailnetDiagnostics and MoMoAgentClient. No account sign-in or device approval.
/// Print only success/timing, never the one-time authorization URL.
@main struct TailnetLoginProbe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("momo-login-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = EmbeddedTailnet(directory: directory, device: "probe")
        let start = ContinuousClock.now
        do {
            let url = try await network.loginURL()
            guard url?.scheme == "https", url?.host == "login.tailscale.com" else {
                throw TailnetError.loginUnavailable
            }
            print("auth_url_received=true elapsed=\(start.duration(to: .now))")
            let repeated = try await network.loginURL()
            guard repeated == url else { throw TailnetError.loginUnavailable }
            print("reused_url=true")
            await network.close()
        } catch {
            await network.close()
            throw error
        }
    }
}
