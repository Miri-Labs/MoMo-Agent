import Foundation

/// Bound unattended recovery while the OS permits execution; progress starts a new short interval.
public struct LinkRetryBackoff: Sendable {
    private var delay: TimeInterval = 30
    public init() {}
    public mutating func nextDelay() -> TimeInterval {
        let current = delay
        delay = min(300, delay * 2)
        return current
    }
    public mutating func reset() { delay = 30 }
}
