import Foundation
import MoMoContracts

/// A successful, unrelated transfer must not clear another command's failure.
public struct LinkControlFailureState: Sendable {
    private var failures: [String: (message: ControlMessage, failure: TransportFailure)] = [:]
    private var dismissed: Set<String> = []
    public var failure: TransportFailure? { failure(where: { _ in true }) }
    public var failedMessages: [ControlMessage] { failures.values.map(\.message) }
    public init() {}

    /// Presentation can exclude a transient or dismissed failure without forgetting its pending command.
    public func failure(where shouldPresent: (TransportFailure) -> Bool) -> TransportFailure? {
        failures.lazy.compactMap { dismissed.contains($0.key) ? nil : $0.value.failure }.first(where: shouldPresent)
    }

    /// Suppresses already-surfaced banners until a command fails again on a later attempt.
    public mutating func dismissCurrentFailures() {
        dismissed.formUnion(failures.keys)
    }

    public mutating func didFinish(_ message: ControlMessage, failure: TransportFailure?) throws {
        let key = ContentHash.sha256(try WireJSON.encode(message))
        if let failure {
            failures[key] = (message, failure)
            dismissed.remove(key)
        } else {
            failures.removeValue(forKey: key)
            dismissed.remove(key)
        }
    }
}
