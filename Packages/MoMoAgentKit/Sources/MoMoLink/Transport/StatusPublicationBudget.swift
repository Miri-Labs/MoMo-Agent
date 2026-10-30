import Foundation

/// Replaceable status has its own budget; capture and durable receipts never wait for it.
public struct StatusPublicationBudget: Sendable {
    public static let passiveInterval: TimeInterval = 60
    public static let viewingInterval: TimeInterval = 5
    private var lastAttempt: TimeInterval = -.infinity
    private var retryAt: TimeInterval = -.infinity
    private var backoff = LinkRetryBackoff()
    private var viewingUntil: TimeInterval = -.infinity

    public init() {}

    @discardableResult public mutating func peerRequestedStatus(now: TimeInterval, viewing: Bool = false) -> Bool {
        let beganViewing = viewing && now >= viewingUntil
        if viewing { viewingUntil = now + 15 }
        lastAttempt = now
        return beganViewing
    }

    public func isPeerViewing(now: TimeInterval) -> Bool {
        now < viewingUntil
    }

    public func isDue(now: TimeInterval, urgent: Bool) -> Bool {
        guard now >= retryAt else { return false }
        let interval = now < viewingUntil ? Self.viewingInterval : Self.passiveInterval
        return urgent || now - lastAttempt >= interval
    }

    public mutating func beganAttempt(now: TimeInterval) { lastAttempt = now }
    public mutating func succeeded() { retryAt = -.infinity; backoff.reset() }
    public mutating func failed(now: TimeInterval) { retryAt = now + backoff.nextDelay() }
}
