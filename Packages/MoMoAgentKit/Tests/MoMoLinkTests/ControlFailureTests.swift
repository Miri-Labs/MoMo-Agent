import Foundation
import Testing
import MoMoContracts
import MoMoLink

@Test func retiringForeignRetriesDoesNotAcknowledgeTheMessageOrFreeOutstandingCapacity() throws {
    let messages = (0..<33).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    for message in messages.prefix(32) { #expect(try state.reserve(message, now: 100) == .submitted) }
    try state.stopRetrying(messages[0])
    #expect(try state.reserve(messages[32], now: 100) == .deferred)
    #expect(try state.didFinish(messages[0], failed: true, now: 101))
    #expect(state.hasRetryableControls)
    try state.stopRetrying(messages[0])
    #expect(!state.hasRetryableControls)
    #expect(try state.reserve(messages[0], now: 102) == .submitted)
}

@Test func controlFailureRetainsSystemCodeInsteadOfOnlyUnknownDescription() {
    let failure = TransportFailure(NSError(domain: "WCErrorDomain", code: 7001,
        userInfo: [NSLocalizedDescriptionKey: "未知错误"]))
    #expect(failure.diagnosticDescription == "未知错误（WCErrorDomain 7001）")
}

@Test func controlRecoveryClearsOnlyItsOwnFailureAndDoesNotDeclareOtherCommandsRecovered() throws {
    let first = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let second = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let unrelated = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let failure = TransportFailure(NSError(domain: "WCErrorDomain", code: 7001))
    var state = LinkControlFailureState()
    try state.didFinish(first, failure: failure)
    try state.didFinish(second, failure: failure)
    try state.didFinish(unrelated, failure: nil)
    #expect(state.failure == failure)
    try state.didFinish(first, failure: nil)
    #expect(state.failure == failure)
    try state.didFinish(second, failure: nil)
    #expect(state.failure == nil)
}

@Test func durableAcknowledgementStopsRetryWithoutFreeingAnOutstandingSystemCopy() throws {
    let messages = (0..<33).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    for message in messages.prefix(32) { #expect(try state.reserve(message, now: 100) == .submitted) }
    try state.confirmDelivery(messages[0])
    #expect(try state.reserve(messages[32], now: 100) == .deferred)
    #expect(try !state.didFinish(messages[0], failed: true, now: 100))
    #expect(!state.hasRetryableControls)
    #expect(try state.reserve(messages[0], now: 500) == .alreadySubmitted)
    #expect(try state.reserve(messages[32], now: 101) == .submitted)
}

@Test func brokenControlChannelDoesNotConsumeTheWholePendingReceiptBacklog() throws {
    let receiver = UUID(), library = UUID(), hash = String(repeating: "a", count: 64)
    let messages = try (0..<1412).map { _ in ControlMessage.receipt(try Receipt(
        receiverDeviceID: receiver, libraryInstanceID: library, chunkID: UUID(), audioSHA256: hash, manifestSHA256: hash)) }
    var state = LinkControlSubmissionState()
    var perMessageOnly = LinkControlSubmissionState()
    var submissions = 0, previousSubmissions = 0
    for (index, message) in messages.enumerated() {
        let now = 100 + Double(index) / 1000
        if try perMessageOnly.reserve(message, now: now) == .submitted {
            previousSubmissions += 1
            try perMessageOnly.didFinish(message, failed: true, now: now)
        }
        let admission = try state.reserve(message, now: now)
        if admission == .submitted {
            submissions += 1
            try state.didFinish(message, failed: true, channelFailure: true, now: now)
        } else { #expect(admission == .deferred) }
    }
    #expect(previousSubmissions == 1412)
    #expect(submissions == 1)
    #expect(state.hasRetryableControls)
    state.allowReplay()
    #expect(try state.reserve(messages[1], now: 129) == .deferred)
    #expect(try state.reserve(messages[1], now: 130) == .submitted)
    try state.didFinish(messages[1], failed: true, channelFailure: true, now: 130)
    #expect(try state.reserve(messages[2], now: 189) == .deferred)
    #expect(try state.reserve(messages[2], now: 190) == .submitted)
    try state.didFinish(messages[2], failed: false, now: 191)
    #expect(try state.reserve(messages[3], now: 191) == .submitted)
    try state.didFinish(messages[3], failed: true, channelFailure: true, now: 192)
    #expect(try state.reserve(messages[4], now: 221) == .deferred)
    #expect(try state.reserve(messages[4], now: 222) == .submitted)
}

@Test func failuresOfOneInflightBatchDoNotMultiplyTheChannelBackoff() throws {
    let messages = (0..<33).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    for message in messages.prefix(32) { #expect(try state.reserve(message, now: 100) == .submitted) }
    for message in messages.prefix(32) {
        #expect(try state.didFinish(message, failed: true, channelFailure: true, now: 101))
    }
    state.allowReplay()
    #expect(try state.reserve(messages[32], now: 130) == .deferred)
    #expect(try state.reserve(messages[32], now: 131) == .submitted)
}

@Test func durableInboxReplyWinsOverLateBackgroundFailureWithoutConfirmingOtherMessages() throws {
    let delivered = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let unrelated = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(delivered, now: 100) == .submitted)
    #expect(try state.reserve(unrelated, now: 100) == .submitted)
    try state.confirmDelivery(delivered)
    #expect(try state.deliveryIsConfirmed(delivered))
    #expect(try !state.deliveryIsConfirmed(unrelated))
    #expect(try !state.didFinish(delivered, failed: true, channelFailure: true, now: 101))
    #expect(!state.hasRetryableControls)
    #expect(try state.didFinish(unrelated, failed: true, channelFailure: true, now: 101))
    #expect(state.hasRetryableControls)
}

@Test func anOlderInflightSuccessCannotReopenTheChannelDuringCooldown() throws {
    let messages = (0..<3).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(messages[0], now: 100) == .submitted)
    #expect(try state.reserve(messages[1], now: 100) == .submitted)
    try state.didFinish(messages[0], failed: true, channelFailure: true, now: 101)
    try state.didFinish(messages[1], failed: false, now: 102)
    #expect(try state.reserve(messages[2], now: 130) == .deferred)
    #expect(try state.reserve(messages[2], now: 131) == .submitted)
}

@Test func channelRecoveryAdmitsOnlyOneProbeAndAnOlderSuccessCannotOpenIt() throws {
    let messages = (0..<5).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(messages[0], now: 100) == .submitted)
    #expect(try state.reserve(messages[1], now: 100) == .submitted)
    try state.didFinish(messages[0], failed: true, channelFailure: true, now: 101)
    #expect(try state.reserve(messages[2], now: 131) == .submitted)
    #expect(try state.reserve(messages[3], now: 131) == .deferred)
    try state.didFinish(messages[1], failed: false, now: 132)
    state.allowReplay()
    #expect(try state.reserve(messages[3], now: 132) == .deferred)
    try state.didFinish(messages[2], failed: false, now: 133)
    #expect(try state.reserve(messages[3], now: 133) == .submitted)
    #expect(try state.reserve(messages[4], now: 133) == .submitted)
}

@Test func generalReplayCannotForgetCustodyButExplicitBusinessReplayCan() throws {
    let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(message, now: 100) == .submitted)
    try state.confirmDelivery(message)
    try state.reconcile([])
    state.allowReplay()
    #expect(try state.reserve(message, now: 200) == .alreadySubmitted)
    try state.allowReplay(message)
    #expect(try state.reserve(message, now: 200) == .submitted)
}

@Test func custodyDoesNotFalselyDeclareTheUnderlyingBackgroundChannelHealthy() throws {
    let broken = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let next = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(broken, now: 100) == .submitted)
    #expect(try state.reserve(message, now: 100) == .submitted)
    try state.didFinish(broken, failed: true, channelFailure: true, now: 101)
    try state.confirmDelivery(message)
    let deliveryFailed = try state.didFinish(message, failed: true, channelFailure: true, now: 102)
    #expect(!deliveryFailed)
    #expect(try state.reserve(next, now: 102) == .deferred)
    #expect(try state.reserve(next, now: 131) == .submitted)
}

@Test func aProbeLostFromTheSdkSnapshotBacksOffWithoutPermanentlyOccupyingTheRoute() throws {
    let first = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let probe = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let next = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(first, now: 100) == .submitted)
    try state.didFinish(first, failed: true, channelFailure: true, now: 101)
    #expect(try state.reserve(probe, now: 131) == .submitted)
    try state.reconcile([], now: 132)
    #expect(state.hasRetryableControls)
    #expect(try state.reserve(next, now: 133) == .deferred)
    #expect(try state.reserve(next, now: 192) == .submitted)
}
