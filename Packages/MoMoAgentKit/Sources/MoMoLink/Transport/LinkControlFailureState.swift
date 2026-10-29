import Foundation
import MoMoContracts

/// A successful, unrelated transfer must not clear another command's failure.
public struct LinkControlFailureState: Sendable {
    private var failures: [String: (message: ControlMessage, failure: TransportFailure)] = [:]
    public var failure: TransportFailure? { failures.values.first?.failure }
    public var failedMessages: [ControlMessage] { failures.values.map(\.message) }
    public init() {}

    /// Presentation can exclude a transient failure without forgetting its pending command.
    public func failure(where shouldPresent: (TransportFailure) -> Bool) -> TransportFailure? {
        failures.values.lazy.map(\.failure).first(where: shouldPresent)
    }

    public mutating func didFinish(_ message: ControlMessage, failure: TransportFailure?) throws {
        let key = ContentHash.sha256(try WireJSON.encode(message))
        failures[key] = failure.map { (message, $0) }
    }
}
