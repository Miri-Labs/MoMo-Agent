import Foundation
import MoMoContracts

public enum ControlSubmissionResult: Sendable, Equatable { case submitted, alreadySubmitted, deferred, retryLater }

public struct LinkControlBudget: Sendable {
    public static let maximumCount = 32
    public private(set) var count = 0
    public private(set) var bytes = 0
    public init() {}

    public mutating func include(_ message: ControlMessage) throws -> Bool {
        let size = try WireJSON.encode(message).count
        guard size <= LinkWireFormat.maximumControlBytes else { throw LinkError.controlMessageTooLarge }
        guard count < Self.maximumCount, bytes + size <= LinkWireFormat.maximumControlBytes else { return false }
        count += 1; bytes += size
        return true
    }
}

/// Submission is remembered only for this activation. Durable stores retain every replayable message.
public struct LinkControlSubmissionState: Sendable {
    private var submitted: Set<String> = []
    private var outstanding: [String: (bytes: Int, count: Int)] = [:]
    private var retryNotBefore: [String: TimeInterval] = [:]
    private var backoffs: [String: LinkRetryBackoff] = [:]
    private var delivered: Set<String> = []
    private var channelRetryNotBefore: TimeInterval?
    private var channelProbeHash: String?
    private var channelBackoff = LinkRetryBackoff()
    private let maximumOutstandingCount: Int
    public var hasRetryableControls: Bool { !retryNotBefore.isEmpty }
    public var isRecoveringChannel: Bool { channelRetryNotBefore != nil }
    public func hasDueControlRetries(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !retryNotBefore.isEmpty else { return false }
        if let channelRetryAt = channelRetryNotBefore, now < channelRetryAt { return false }
        if channelRetryNotBefore != nil, channelProbeHash != nil { return false }
        return retryNotBefore.contains { hash, retryAt in outstanding[hash] == nil && now >= retryAt }
    }
    public func nextRetryDelay(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard !retryNotBefore.isEmpty else { return nil }
        if channelRetryNotBefore != nil, channelProbeHash != nil { return nil }
        let channelFloor = channelRetryNotBefore ?? -.infinity
        return retryNotBefore.compactMap { hash, retryAt -> TimeInterval? in
            guard outstanding[hash] == nil else { return nil }
            let dueAt = max(retryAt, channelFloor)
            return dueAt > now ? dueAt - now : nil
        }.min()
    }
    public init(maximumOutstandingCount: Int = LinkControlBudget.maximumCount) {
        precondition((1...LinkControlBudget.maximumCount).contains(maximumOutstandingCount))
        self.maximumOutstandingCount = maximumOutstandingCount
    }
    public func deliveryIsConfirmed(_ message: ControlMessage) throws -> Bool {
        delivered.contains(ContentHash.sha256(try WireJSON.encode(message)))
    }
    public mutating func allowReplay() { submitted.removeAll() }
    public mutating func allowReplay(_ message: ControlMessage) throws {
        let hash = ContentHash.sha256(try WireJSON.encode(message))
        submitted.remove(hash)
        delivered.remove(hash)
    }

    /// Retiring a command for a different peer does not acknowledge it or release a system copy.
    public mutating func stopRetrying(_ message: ControlMessage) throws {
        let hash = ContentHash.sha256(try WireJSON.encode(message))
        retryNotBefore.removeValue(forKey: hash)
        backoffs.removeValue(forKey: hash)
        if channelProbeHash == hash { channelProbeHash = nil }
    }

    public mutating func confirmDelivery(_ message: ControlMessage) throws {
        let hash = ContentHash.sha256(try WireJSON.encode(message))
        submitted.insert(hash)
        delivered.insert(hash)
        retryNotBefore.removeValue(forKey: hash)
        backoffs.removeValue(forKey: hash)
        // Keep the outstanding system copy in the budget until its own callback arrives.
    }

    public mutating func reconcile(_ messages: [ControlMessage], now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        var current: [String: (bytes: Int, count: Int)] = [:]
        for message in messages {
            let data = try WireJSON.encode(message)
            guard data.count <= LinkWireFormat.maximumControlBytes else { throw LinkError.controlMessageTooLarge }
            let hash = ContentHash.sha256(data)
            current[hash] = (data.count, (current[hash]?.count ?? 0) + 1)
        }
        if let probe = channelProbeHash, current[probe] == nil {
            // A lost SDK callback must not leave the half-open route permanently occupied.
            channelProbeHash = nil
            submitted.remove(probe)
            let retryAt = now + channelBackoff.nextDelay()
            channelRetryNotBefore = retryAt
            if !delivered.contains(probe) { retryNotBefore[probe] = retryAt }
        }
        outstanding = current
    }

    public mutating func reserve(_ message: ControlMessage, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> ControlSubmissionResult {
        let data = try WireJSON.encode(message)
        guard data.count <= LinkWireFormat.maximumControlBytes else { throw LinkError.controlMessageTooLarge }
        let hash = ContentHash.sha256(data)
        if delivered.contains(hash) || submitted.contains(hash) || outstanding[hash] != nil { return .alreadySubmitted }
        // A broken channel must not drain a large outbox by failing a different message each time.
        if let retryAt = channelRetryNotBefore, now < retryAt { return .deferred }
        if channelRetryNotBefore != nil, let probe = channelProbeHash, probe != hash { return .deferred }
        if let retryAt = retryNotBefore[hash], now < retryAt { return .retryLater }
        guard outstanding.values.reduce(0, { $0 + $1.count }) < maximumOutstandingCount,
              outstanding.values.reduce(0, { $0 + $1.bytes * $1.count }) + data.count <= LinkWireFormat.maximumControlBytes else { return .deferred }
        submitted.insert(hash)
        delivered.remove(hash)
        outstanding[hash] = (data.count, 1)
        if channelRetryNotBefore != nil { channelProbeHash = hash }
        retryNotBefore.removeValue(forKey: hash)
        return .submitted
    }

    /// Returns whether the logical delivery still failed after considering the peer's durable inbox reply.
    @discardableResult public mutating func didFinish(_ message: ControlMessage, failed: Bool,
        channelFailure: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        let hash = ContentHash.sha256(try WireJSON.encode(message))
        let deliveryFailed = failed && !delivered.contains(hash)
        let finishedProbe = channelProbeHash == hash
        if let known = outstanding[hash], known.count > 1 { outstanding[hash] = (known.bytes, known.count - 1) }
        else { outstanding.removeValue(forKey: hash) }
        if deliveryFailed {
            submitted.remove(hash)
            var backoff = backoffs[hash] ?? LinkRetryBackoff()
            retryNotBefore[hash] = now + backoff.nextDelay()
            backoffs[hash] = backoff
        } else {
            retryNotBefore.removeValue(forKey: hash)
            backoffs.removeValue(forKey: hash)
        }
        // Retiring a confirmed system copy can itself finish with an error; it is not a new failed delivery.
        if deliveryFailed, channelFailure, now >= (channelRetryNotBefore ?? -.infinity) {
            channelRetryNotBefore = now + channelBackoff.nextDelay()
        }
        if failed, finishedProbe { channelProbeHash = nil }
        // Only the half-open probe's transport success can reopen this route.
        if !failed, finishedProbe { recoverChannel() }
        return deliveryFailed
    }

    private mutating func recoverChannel() {
        channelRetryNotBefore = nil
        channelProbeHash = nil
        channelBackoff.reset()
    }
}

public enum LinkBackgroundDrainResult: Sendable, Equatable { case pending, completed, failed }

public enum LinkBackgroundDrain {
    public static func result(activation: LinkActivation, hasPendingContent: Bool, processing: Bool) -> LinkBackgroundDrainResult {
        switch activation {
        case .inactive, .failed: .failed
        case .activating: .pending
        case .activated: hasPendingContent || processing ? .pending : .completed
        }
    }
}
