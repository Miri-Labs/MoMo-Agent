import Foundation

/// A local WCSession selection, not a Watch-reported device identity or a wire message.
public struct SelectedWatchContext: Sendable, Equatable {
    public let epoch: UUID
    public let sequence: UInt64
    public let activation: LinkActivation
    public let peerState: LinkPeerState
    public let directoryURL: URL?

    public var isAvailable: Bool {
        activation == .activated && peerState == .available && directoryURL != nil
    }
}

/// Stamp callbacks before leaving WCSession's serial delegate queue. MainActor delivery may reorder them.
public final class SelectedWatchEventClock: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()
    private var sequence: UInt64 = 0
    private var activation: LinkActivation = .inactive
    private var peerState: LinkPeerState = .notPaired
    private var directoryURL: URL?

    public init() {}

    public func select(activation: LinkActivation, peerState: LinkPeerState, directoryURL: URL?) -> SelectedWatchContext {
        lock.lock()
        defer { lock.unlock() }
        let directory = activation == .activated && peerState == .available
            ? directoryURL?.standardizedFileURL : nil
        if self.activation != activation || self.peerState != peerState || self.directoryURL != directory {
            epoch = UUID()
            self.activation = activation
            self.peerState = peerState
            self.directoryURL = directory
        }
        return next()
    }

    public func receive() -> SelectedWatchContext {
        lock.lock()
        defer { lock.unlock() }
        return next()
    }

    private func next() -> SelectedWatchContext {
        precondition(sequence < UInt64.max)
        sequence += 1
        return SelectedWatchContext(epoch: epoch, sequence: sequence, activation: activation,
            peerState: peerState, directoryURL: directoryURL)
    }
}
