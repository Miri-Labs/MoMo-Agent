import Foundation
import Testing
import MoMoContracts
import MoMoLink

private func linkEnvelope() throws -> ManifestEnvelope {
    try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test", sequence: 0, frames: FrameRange(start: 0, count: 8), timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 8, byteCount: 16, audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 16)), sourceKind: .fixture))
}

@Test func unattendedRecoveryBacksOffAndProgressRestartsTheShortInterval() {
    var backoff = LinkRetryBackoff()
    #expect((0..<7).map { _ in backoff.nextDelay() } == [30, 60, 120, 240, 300, 300, 300])
    backoff.reset()
    #expect(backoff.nextDelay() == 30)
}

@Test func repairingAnUnreadableSystemQueuePreservesHealthyCopiesAndChannelCooldown() throws {
    let messages = (0..<3).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    for message in messages { #expect(try state.reserve(message, now: 0) == .submitted) }
    try state.didFinish(messages[2], failed: true, channelFailure: true, now: 10)
    // The first SDK copy was cancelled after its metadata became unusable; its durable outbox remains.
    state.allowReplay()
    try state.reconcile([messages[1]])
    #expect(try state.reserve(messages[0], now: 20) == .deferred)
    #expect(try state.reserve(messages[1], now: 20) == .alreadySubmitted)
    #expect(try state.reserve(messages[0], now: 40) == .submitted)
    #expect(try state.reserve(messages[2], now: 40) == .deferred)
    #expect(try state.reserve(messages[1], now: 40) == .alreadySubmitted)
    try state.didFinish(messages[0], failed: false, now: 41)
    #expect(try state.reserve(messages[2], now: 41) == .submitted)
}

@Test func failedFileCoolsDownWithoutBlockingOtherFilesAndConfirmedTransfersStayComplete() throws {
    let failed = try linkEnvelope()
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    #expect(try state.reserve(failed, now: 100) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, failed: true, now: 100)
    #expect(state.hasRetryableFiles)
    #expect(try state.reserve(failed, now: 129) == .retryLater)
    let healthy = try (0..<4).map { _ in try linkEnvelope() }
    for file in healthy { #expect(try state.reserve(file, now: 101) == .submitted) }
    #expect(try state.reserve(failed, now: 130) == .deferred)
    state.didFinish(chunkID: healthy[0].manifest.chunkID, now: 130)
    #expect(try state.reserve(failed, now: 130) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, failed: true, now: 130)
    #expect(try state.reserve(failed, now: 189) == .retryLater)
    #expect(try state.reserve(failed, now: 190) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, now: 191)
    for file in [failed, healthy[0]] {
        try state.confirmFileDelivery(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(),
            chunkID: file.manifest.chunkID, audioSHA256: file.manifest.audioSHA256,
            manifestSHA256: file.manifestSHA256))
    }
    #expect(!state.hasRetryableFiles)
    #expect(try state.reserve(failed, now: 500) == .alreadySubmitted)
    #expect(try state.reserve(healthy[0], now: 500) == .alreadySubmitted)
}

@Test func repeatedReconciliationCanReplayOnlyItsResponseWithoutDuplicatingQueuedControls() throws {
    let first = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let second = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(first) == .submitted)
    #expect(try state.reserve(second) == .submitted)
    try state.didFinish(first, failed: false)
    try state.didFinish(second, failed: false)
    try state.allowReplay(first)
    #expect(try state.reserve(first) == .submitted)
    #expect(try state.reserve(second) == .alreadySubmitted)
    try state.allowReplay(first)
    #expect(try state.reserve(first) == .alreadySubmitted)
}

@Test func unreachablePhoneStillAllowsBackgroundFileSubmission() throws {
    let envelope = try linkEnvelope()
    var state = LinkSubmissionState()
    #expect(throws: LinkError.notActivated) { try state.shouldSubmit(envelope) }
    state.update(activation: .activated, isReachable: false)
    #expect(try state.shouldSubmit(envelope))
    #expect(try !state.shouldSubmit(envelope))
    #expect(throws: LinkError.notReachable) { try state.requireImmediateMessaging() }
    state.didFinish(chunkID: envelope.manifest.chunkID)
    #expect(try !state.shouldSubmit(envelope))
    state.allowFileReplay()
    #expect(try state.shouldSubmit(envelope))
}

@Test func metadataRoundTripPreservesOriginalManifestAndRejectsMismatchedIdentity() throws {
    let envelope = try linkEnvelope()
    let metadata = LinkWireFormat.fileMetadata(envelope)
    #expect(try LinkWireFormat.fileEnvelope(metadata) == envelope)
    var changed = metadata
    changed["chunk_id"] = "../../private"
    #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.fileEnvelope(changed) }
    changed["chunk_id"] = UUID().uuidString
    #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.fileEnvelope(changed) }
    #expect(throws: LinkError.controlMessageTooLarge) {
        try LinkWireFormat.controlMessage(["protocol_version": 1, "control": Data(repeating: 0, count: 16_385)])
    }
}

@Test func outstandingTransferReconciliationPreventsDuplicateSubmission() throws {
    let envelope = try linkEnvelope()
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: true)
    try state.reconcile([envelope])
    #expect(try !state.shouldSubmit(envelope))
    try state.reconcile([])
    #expect(try !state.shouldSubmit(envelope))
    state.allowFileReplay()
    #expect(try state.shouldSubmit(envelope))
}

@Test func outstandingFileBudgetIncludesTransfersRecoveredFromTheSystemQueue() throws {
    let envelopes = try (0..<5).map { _ in try linkEnvelope() }
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    try state.reconcile(Array(envelopes.prefix(4)))
    let full = try state.shouldSubmit(envelopes[4])
    #expect(!full)
    state.didFinish(chunkID: envelopes[0].manifest.chunkID)
    let admitted = try state.shouldSubmit(envelopes[4])
    #expect(admitted)
    let sixth = try state.shouldSubmit(linkEnvelope())
    #expect(!sixth)
    try state.reconcile(Array(repeating: envelopes[0], count: 4))
    let legacyDuplicateQueue = try state.shouldSubmit(envelopes[4])
    #expect(!legacyDuplicateQueue)
    state.didFinish(chunkID: envelopes[0].manifest.chunkID)
    let stillOutstanding = try state.shouldSubmit(envelopes[0])
    #expect(!stillOutstanding)
    let freedSlot = try state.shouldSubmit(linkEnvelope())
    #expect(freedSlot)
}

@Test func controlQueueEnforcesCountAndEncodedByteBudgetAndRetriesOnlyFailedMessages() throws {
    let messages: [ControlMessage] = (0..<40).map { _ in .deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    var accepted: [ControlMessage] = []
    for message in messages {
        let result = try state.reserve(message)
        if case .submitted = result { accepted.append(message) }
    }
    #expect(accepted.count == 32)
    #expect(try accepted.reduce(0) { try $0 + WireJSON.encode($1).count } <= LinkWireFormat.maximumControlBytes)
    try state.didFinish(messages[0], failed: false)
    let completed = try state.reserve(messages[0])
    #expect(completed == .alreadySubmitted)
    let next = try state.reserve(messages[32])
    #expect(next == .submitted)
    try state.didFinish(messages[1], failed: true, now: 100)
    #expect(try state.reserve(messages[1], now: 129) == .retryLater)
    let retry = try state.reserve(messages[1], now: 130)
    #expect(retry == .submitted)
    state.allowReplay()
    let duplicate = try state.reserve(messages[1])
    #expect(duplicate == .alreadySubmitted)
    try state.reconcile([])
    let replay = try state.reserve(messages[0])
    #expect(replay == .submitted)
    state.allowReplay()
    try state.reconcile(Array(repeating: messages[0], count: 32))
    let legacyQueue = try state.reserve(messages[39])
    #expect(legacyQueue == .deferred)
}

@Test func failedControlBacksOffWithoutBlockingHealthyMessagesAndReplayCannotBypassIt() throws {
    let failed = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let healthy = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(failed, now: 100) == .submitted)
    try state.didFinish(failed, failed: true, now: 100)
    #expect(state.hasRetryableControls)
    state.allowReplay()
    #expect(try state.reserve(failed, now: 129) == .retryLater)
    #expect(try state.reserve(healthy, now: 101) == .submitted)
    #expect(try state.reserve(failed, now: 130) == .submitted)
    try state.didFinish(failed, failed: true, now: 130)
    try state.allowReplay(failed)
    #expect(try state.reserve(failed, now: 189) == .retryLater)
    #expect(try state.reserve(failed, now: 190) == .submitted)
    try state.didFinish(failed, failed: false, now: 191)
    #expect(!state.hasRetryableControls)
    #expect(try state.reserve(failed, now: 500) == .alreadySubmitted)
    #expect(try state.reserve(healthy, now: 500) == .alreadySubmitted)
}

@Test func controlBatchStopsAtBytesBeforeThirtyTwoReceipts() throws {
    let m = try linkEnvelope().manifest
    var state = LinkControlSubmissionState()
    var batch = LinkControlBudget()
    var bytes = 0, count = 0
    for _ in 0..<40 {
        let receipt = try Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: m.chunkID,
                                  audioSHA256: m.audioSHA256, manifestSHA256: String(repeating: "a", count: 64))
        let message = ControlMessage.receiptApplied(ReceiptApplied(receipt: receipt))
        let included = try batch.include(message)
        let submitted = try state.reserve(message)
        if included {
            #expect(submitted == .submitted)
            bytes += try WireJSON.encode(message).count; count += 1
        } else { #expect(submitted == .deferred) }
    }
    #expect(count > 0 && count < 32)
    #expect(bytes <= LinkWireFormat.maximumControlBytes)
}

@Test func failedActivationFinishesCurrentGrantWithoutWaitingForFutureConnectivity() {
    #expect(LinkBackgroundDrain.result(activation: .failed, hasPendingContent: true, processing: false) == .failed)
    #expect(LinkBackgroundDrain.result(activation: .inactive, hasPendingContent: false, processing: false) == .failed)
    #expect(LinkBackgroundDrain.result(activation: .activating, hasPendingContent: false, processing: false) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: true, processing: false) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: false, processing: true) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: false, processing: false) == .completed)
}

@Test @MainActor func expirationAndDrainCleanupCompleteEachGrantOnceWithoutTouchingANewGrant() {
    let registry = LinkRefreshTasks<UUID>()
    let first = UUID(), second = UUID(), next = UUID()
    var firstCount = 0, secondCount = 0, nextCount = 0
    registry.insert(first) {
        firstCount += 1
        registry.completeAll()
    }
    registry.insert(second) { secondCount += 1 }
    registry.completeAll()
    registry.complete(first)
    registry.complete(second)
    #expect(firstCount == 1 && secondCount == 1 && registry.isEmpty)
    registry.insert(next) { nextCount += 1 }
    // An expiration already queued for the old task must not cancel the next OS grant.
    if registry.contains(first) { registry.completeAll() }
    #expect(nextCount == 0 && registry.contains(next))
    registry.completeAll()
    registry.completeAll()
    #expect(nextCount == 1 && registry.isEmpty)
}
