import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor @Observable
final class TailnetLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    var busy = false
    var error: String?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func begin(_ network: EmbeddedTailnet) {
        guard !busy else { return }
        busy = true; error = nil; generation = UUID()
        let attempt = generation
        monitor = Task {
            defer { if generation == attempt { busy = false } }
            do {
                guard let url = try await network.loginURL() else { return }
                guard generation == attempt, !Task.isCancelled else { return }
                let web = ASWebAuthenticationSession(url: url, callbackURLScheme: "ipnauth", completionHandler: Self.completion(self, attempt: attempt))
                web.presentationContextProvider = self; session = web
                guard web.start() else { throw TailnetError.loginUnavailable }
                while !Task.isCancelled, !["Running", "NeedsMachineAuth", "failed"].contains(network.state) {
                    try await Task.sleep(for: .milliseconds(300))
                    guard generation == attempt, !Task.isCancelled else { break }
                    await network.refreshStatus()
                }
                guard generation == attempt, !Task.isCancelled else { return }
                let terminalState = network.state
                let terminalMessage = network.message
                generation = UUID()
                web.cancel(); session = nil; monitor = nil; busy = false
                if terminalState == "NeedsMachineAuth" {
                    self.error = TailnetError.approvalRequired.localizedDescription
                } else if terminalState == "failed" {
                    self.error = terminalMessage ?? TailnetError.unavailable.localizedDescription
                }
            } catch is CancellationError { }
            catch { if generation == attempt { self.error = error.localizedDescription } }
        }
    }

    func cancel() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        session?.cancel(); session = nil; busy = false
    }

    nonisolated private static func completion(_ owner: TailnetLogin, attempt: UUID) -> @Sendable (URL?, Error?) -> Void {
        { _, _ in Task { @MainActor in
            guard owner.generation == attempt else { return }
            owner.cancel()
        } }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
