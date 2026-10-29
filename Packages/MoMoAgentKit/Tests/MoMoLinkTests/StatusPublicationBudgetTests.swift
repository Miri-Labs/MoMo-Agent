import Testing
@testable import MoMoLink

struct StatusPublicationBudgetTests {
    @Test func enteringAViewingPeriodCanFlushAudioButRepeatedStatusPollsDoNot() {
        var budget = StatusPublicationBudget()
        let first = budget.peerRequestedStatus(now: 0, viewing: true)
        #expect(first)
        for now in stride(from: 5.0, through: 100.0, by: 5) {
            let repeated = budget.peerRequestedStatus(now: now, viewing: true)
            #expect(!repeated)
        }
        let reopened = budget.peerRequestedStatus(now: 116, viewing: true)
        #expect(reopened)
    }

    @Test func backgroundStatusRequestsRefreshObservationWithoutOpeningOrExtendingViewing() {
        var budget = StatusPublicationBudget()
        let passive = budget.peerRequestedStatus(now: 0)
        #expect(!passive)
        #expect(!budget.isDue(now: 5, urgent: false))
        #expect(budget.isDue(now: 60, urgent: false))
        let viewing = budget.peerRequestedStatus(now: 70, viewing: true)
        #expect(viewing)
        let background = budget.peerRequestedStatus(now: 80)
        #expect(!background)
        #expect(!budget.isDue(now: 85, urgent: false))
        #expect(budget.isDue(now: 140, urgent: false))
        let reopened = budget.peerRequestedStatus(now: 141, viewing: true)
        #expect(reopened)
    }
    @Test func passiveRecordingUsesSixtyPublicationsPerHourAndTransitionsAreImmediate() {
        var budget = StatusPublicationBudget()
        var attempts = 0
        for tick in 0..<18_000 {
            let now = Double(tick) / 5
            if budget.isDue(now: now, urgent: false) {
                budget.beganAttempt(now: now); budget.succeeded(); attempts += 1
            }
        }
        #expect(attempts == 60)
        #expect(budget.isDue(now: 3_599.9, urgent: true))
    }

    @Test func failingPublisherCannotRetryOnEveryCaptureOrForcedCallback() {
        var budget = StatusPublicationBudget()
        var attempts: [Double] = []
        for tick in 0..<3_000 {
            let now = Double(tick) / 5
            if budget.isDue(now: now, urgent: true) {
                budget.beganAttempt(now: now); budget.failed(now: now); attempts.append(now)
            }
        }
        #expect(attempts == [0, 30, 90, 210, 450])
        budget.peerRequestedStatus(now: 500)
        #expect(!budget.isDue(now: 501, urgent: true), "A status request must not clear delivery backoff.")
        budget.succeeded()
        #expect(budget.isDue(now: 501, urgent: true))
    }

    @Test func viewingLeaseExpiresWithoutNeedingADisconnectMessage() {
        var budget = StatusPublicationBudget()
        budget.peerRequestedStatus(now: 0, viewing: true)
        #expect(!budget.isDue(now: 4.9, urgent: false))
        #expect(budget.isDue(now: 5, urgent: false))
        budget.beganAttempt(now: 5); budget.succeeded()
        budget.peerRequestedStatus(now: 10, viewing: true)
        #expect(budget.isDue(now: 15, urgent: false))
        budget.beganAttempt(now: 15); budget.succeeded()
        #expect(!budget.isDue(now: 25, urgent: false))
        #expect(budget.isDue(now: 75, urgent: false))
    }
}
