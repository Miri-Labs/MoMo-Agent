import Foundation

/// The access service expires desktop reports after 15 seconds. Verifying the
/// forwarded identity is more expensive and has its own cadence.
struct EmbeddedAccessHealth {
    private var verified: (endpoint: URL, at: ContinuousClock.Instant)?
    var lastReport: ContinuousClock.Instant?

    mutating func confirm(_ endpoint: URL, now: ContinuousClock.Instant = .now) {
        verified = (endpoint, now)
    }

    func needsProbe(_ endpoint: URL, now: ContinuousClock.Instant = .now) -> Bool {
        guard let verified, verified.endpoint == endpoint else { return true }
        return verified.at.duration(to: now) >= .seconds(30)
    }

    func needsReport(now: ContinuousClock.Instant = .now) -> Bool {
        guard let lastReport else { return true }
        return lastReport.duration(to: now) >= .seconds(6)
    }

    func recentlyVerified(_ endpoint: URL, now: ContinuousClock.Instant = .now) -> Bool {
        guard let verified, verified.endpoint == endpoint else { return false }
        return verified.at.duration(to: now) < .seconds(60)
    }
}
