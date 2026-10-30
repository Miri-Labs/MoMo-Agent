import Foundation
import XCTest
import MoMoContracts
@testable import MoMoAgentWatch

final class WatchMicrophoneGateTests: XCTestCase {
    func testOnlyTheLatestRouteObservationCanCommit() throws {
        let gate = WatchMicrophoneGate()
        try activate(gate)
        let earlier = gate.beginRouteObservation()
        let later = gate.beginRouteObservation()
        XCTAssertTrue(gate.commitRouteObservation(later, builtIn: false, reason: 2))
        XCTAssertFalse(gate.commitRouteObservation(earlier, builtIn: true, reason: 1))
        XCTAssertFalse(gate.builtInMicrophoneSelected)
        XCTAssertFalse(gate.allowsInput())
        XCTAssertEqual(gate.takeEvents(), [.routeChanged(reason: 2, builtInMicrophoneSelected: false)])
    }

    func testInterruptionInvalidatesActivationBeforeOrAfterTheRouteQuery() throws {
        let gate = WatchMicrophoneGate()
        let attempt = gate.beginActivation()
        let observedBeforeInterruption = try XCTUnwrap(gate.activationObservation(for: attempt))
        gate.interruptionBegan()
        XCTAssertTrue(gate.interruptionActive)
        XCTAssertFalse(gate.confirmActivation(observedBeforeInterruption, builtIn: true))
        XCTAssertNil(gate.activationObservation(for: attempt))
        gate.interruptionEnded(shouldResume: true)
        XCTAssertFalse(gate.interruptionActive)
        XCTAssertFalse(gate.allowsInput(), "Ending an interruption alone must not reopen input.")
        XCTAssertNil(gate.activationObservation(for: attempt), "Even an already-ended interruption invalidates the old activation.")
        XCTAssertFalse(gate.confirmActivation(observedBeforeInterruption, builtIn: true))
        try activate(gate)
        XCTAssertTrue(gate.allowsInput())
    }

    func testResetAndDeactivationInvalidatePendingActivationAndRouteQueries() throws {
        let gate = WatchMicrophoneGate()
        let beforeReset = gate.beginActivation()
        let resetObservation = try XCTUnwrap(gate.activationObservation(for: beforeReset))
        gate.mediaServicesReset()
        XCTAssertNil(gate.activationObservation(for: beforeReset))
        XCTAssertFalse(gate.confirmActivation(resetObservation, builtIn: true))
        XCTAssertFalse(gate.allowsInput())

        let beforeStop = gate.beginActivation()
        let stopObservation = try XCTUnwrap(gate.activationObservation(for: beforeStop))
        let routeObservation = gate.beginRouteObservation()
        gate.deactivate()
        XCTAssertNil(gate.activationObservation(for: beforeStop))
        XCTAssertFalse(gate.confirmActivation(stopObservation, builtIn: true))
        XCTAssertFalse(gate.commitRouteObservation(routeObservation, builtIn: true, reason: 3))
        XCTAssertFalse(gate.allowsInput())
    }

    func testRouteChangesDuringActivationCannotBeOverwrittenAndLossStaysClosed() throws {
        let gate = WatchMicrophoneGate()
        let attempt = gate.beginActivation()
        let observation = try XCTUnwrap(gate.activationObservation(for: attempt))
        let changed = gate.beginRouteObservation()
        XCTAssertTrue(gate.commitRouteObservation(changed, builtIn: false, reason: 2))
        XCTAssertFalse(gate.confirmActivation(observation, builtIn: true))
        try activate(gate)
        XCTAssertTrue(gate.allowsInput())

        let lost = gate.beginRouteObservation()
        XCTAssertTrue(gate.commitRouteObservation(lost, builtIn: false, reason: 2))
        let returned = gate.beginRouteObservation()
        XCTAssertTrue(gate.commitRouteObservation(returned, builtIn: true, reason: 1))
        XCTAssertTrue(gate.builtInMicrophoneSelected)
        XCTAssertFalse(gate.allowsInput(), "A fresh activation must confirm input after a route loss.")
        let unavailable = gate.beginActivation()
        XCTAssertFalse(gate.confirmActivation(try XCTUnwrap(gate.activationObservation(for: unavailable)), builtIn: false))
        XCTAssertFalse(gate.allowsInput())
        try activate(gate)
        XCTAssertTrue(gate.allowsInput())
    }

    func testQueuedEventsKeepEveryBeginAndResumeDecisionInObservationOrder() {
        let gate = WatchMicrophoneGate()
        gate.interruptionBegan()
        gate.interruptionEnded(shouldResume: false)
        gate.interruptionBegan()
        gate.interruptionEnded(shouldResume: true)
        let route = gate.beginRouteObservation()
        XCTAssertTrue(gate.commitRouteObservation(route, builtIn: true, reason: 1))
        gate.mediaServicesReset()
        XCTAssertEqual(gate.takeEvents(), [
            .interruptionBegan, .interruptionEnded(shouldResume: false),
            .interruptionBegan, .interruptionEnded(shouldResume: true),
            .routeChanged(reason: 1, builtInMicrophoneSelected: true), .mediaServicesReset
        ])
        XCTAssertTrue(gate.takeEvents().isEmpty)
        XCTAssertFalse(gate.allowsInput())
    }

    private func activate(_ gate: WatchMicrophoneGate) throws {
        let attempt = gate.beginActivation()
        let observation = try XCTUnwrap(gate.activationObservation(for: attempt))
        XCTAssertTrue(gate.confirmActivation(observation, builtIn: true))
    }

    func testExplicitRetryRecoversAMissingEndWithoutAdmittingANewInterruption() throws {
        let gate = WatchMicrophoneGate()
        try activate(gate)
        gate.interruptionBegan()
        let automatic = gate.beginActivation()
        XCTAssertNil(gate.activationObservation(for: automatic))
        let manual = gate.beginActivation(recoverInterruptedSession: true)
        XCTAssertFalse(gate.allowsInput(), "A manual retry alone must not open the microphone.")
        let observation = try XCTUnwrap(gate.activationObservation(for: manual))
        gate.interruptionBegan()
        XCTAssertFalse(gate.confirmActivation(observation, builtIn: true))
        let retry = gate.beginActivation(recoverInterruptedSession: true)
        XCTAssertTrue(gate.confirmActivation(try XCTUnwrap(gate.activationObservation(for: retry)), builtIn: true))
        XCTAssertTrue(gate.allowsInput())
    }

    func testMediaResetClearsTheOldServerInterruptionButStillRequiresFreshActivation() throws {
        let gate = WatchMicrophoneGate()
        try activate(gate)
        gate.interruptionBegan()
        gate.mediaServicesReset()
        XCTAssertFalse(gate.interruptionActive)
        XCTAssertFalse(gate.allowsInput())
        try activate(gate)
        XCTAssertTrue(gate.allowsInput())
    }

    func testRestoreInterruptionIfCurrentReassertsInterruptedGateOnlyForCurrentAttempt() throws {
        let gate = WatchMicrophoneGate()
        try activate(gate)
        gate.interruptionBegan()
        XCTAssertTrue(gate.interruptionActive)

        let recovery = gate.beginActivation(recoverInterruptedSession: true)
        XCTAssertFalse(gate.interruptionActive)
        gate.restoreInterruptionIfCurrent(for: recovery)
        XCTAssertTrue(gate.interruptionActive)
        XCTAssertFalse(gate.allowsInput())

        let secondRecovery = gate.beginActivation(recoverInterruptedSession: true)
        gate.restoreInterruptionIfCurrent(for: recovery)
        XCTAssertFalse(gate.interruptionActive, "A stale failed attempt must not re-interrupt a newer activation.")
        let observation = try XCTUnwrap(gate.activationObservation(for: secondRecovery))
        XCTAssertTrue(gate.confirmActivation(observation, builtIn: true))
        XCTAssertTrue(gate.allowsInput())
    }

    func testControlInboxPrioritizesUrgentMessagesAndQuarantinesCorruptFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-priority-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try ControlInbox(directory: root)

        let receiver = UUID(), library = UUID()
        for _ in 0..<6 {
            try inbox.preserve(.receipt(Receipt(
                receiverDeviceID: receiver,
                libraryInstanceID: library,
                chunkID: UUID(),
                audioSHA256: String(repeating: "a", count: 64),
                manifestSHA256: String(repeating: "b", count: 64)
            )))
        }
        let firstPage = try inbox.loadBackgroundPage(limit: 4)
        XCTAssertEqual(firstPage.messages.count, 4)
        XCTAssertTrue(firstPage.hasMore)

        let identity = ControlMessage.receiverIdentity(
            ReceiverIdentity(messageID: UUID(), receiverDeviceID: receiver, libraryInstanceID: library)
        )
        let deletion = ControlMessage.deleteSession(
            try DeleteSession(sessionID: UUID(), generation: 1)
                .scoped(receiverDeviceID: receiver, libraryInstanceID: library)
        )
        try inbox.preserve(identity)
        try inbox.preserve(deletion)
        try Data("not-valid-json".utf8).write(to: root.appendingPathComponent("corrupt-entry.json"))

        let secondPage = try inbox.loadBackgroundPage(limit: 4)
        XCTAssertEqual(secondPage.failures.count, 1)
        XCTAssertEqual(secondPage.messages.first, deletion)
        XCTAssertEqual(secondPage.messages.dropFirst().first, identity)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Quarantine/corrupt-entry.json").path
            )
        )

        let cleanPending = try inbox.pending()
        XCTAssertEqual(cleanPending.first, deletion)
        XCTAssertEqual(cleanPending.dropFirst().first, identity)
        XCTAssertEqual(cleanPending.count, 8)
    }
}
