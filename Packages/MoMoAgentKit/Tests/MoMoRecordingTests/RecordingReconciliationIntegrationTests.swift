import Foundation
import Testing
import MoMoArchive
import MoMoContracts
import MoMoRecording

@Suite struct RecordingReconciliationIntegrationTests {
    @Test func fiveHundredThreePendingChunksRecoverLostReceiptsAndMissingTransfersAcrossRestart() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        var writer = try PCM16SegmentWriter(directory: fixture.root.appendingPathComponent("encoder"),
            sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID, sourceBuild: "backlog-test",
            sourceKind: .fixture, sampleRate: 16_000, targetFrames: 160,
            wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        let encoded = try writer.append(Array(repeating: 0, count: 503 * 160))
        _ = try writer.finish()
        #expect(encoded.count == 503)
        var watch = try fixture.store()
        var phone = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverID)
        try await watch.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: phone.libraryInstanceID)
        var chunks: [UUID: RecordedChunk] = [:]
        for segment in encoded {
            let chunk = try await watch.sealChunk(audioAt: segment.audioURL, envelope: segment.envelope)
            chunks[segment.envelope.manifest.chunkID] = chunk
        }
        // Half reached the phone, but every receipt was lost; the rest never left the Watch.
        for segment in encoded.prefix(251) {
            let chunk = try #require(chunks[segment.envelope.manifest.chunkID])
            _ = try await phone.commitReceivedChunk(deliver(chunk, to: phone, root: fixture.root))
        }
        #expect(try await watch.queueSummary(sessionID: m.sessionID).pendingChunkCount == 503)
        watch = try fixture.store()
        phone = try ArchiveStore(rootURL: phone.rootURL, receiverDeviceID: fixture.receiverID)
        var retransmitted = 0
        var pages = 0
        for _ in 0..<2 {
            var beginNewRound = true
            while let request = try await watch.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID, beginNewRound: beginNewRound) {
                beginNewRound = false
                #expect(request.items.count <= ReconciliationLimits.maximumItems)
                if pages == 8 {
                    watch = try fixture.store()
                    phone = try ArchiveStore(rootURL: phone.rootURL, receiverDeviceID: fixture.receiverID)
                    #expect(try await watch.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID) == request)
                }
                let response = try await phone.receiveReconcileRequest(request)
                let outcome = try await watch.applyReconciliationResponse(response)
                for applied in outcome.receiptApplications { try await phone.applyReceipt(applied) }
                _ = try await watch.cleanupAcknowledgedChunks()
                for offset in stride(from: 0, to: outcome.retryChunkIDs.count, by: 4) {
                    let batch = Array(outcome.retryChunkIDs.dropFirst(offset).prefix(4))
                    for id in batch {
                        let chunk = try #require(chunks[id])
                        #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
                        _ = try await phone.commitReceivedChunk(deliver(chunk, to: phone, root: fixture.root))
                        retransmitted += 1
                    }
                    try await watch.fileReplaysScheduled(batch)
                }
                pages += 1
            }
        }
        #expect(retransmitted == 252, "Files already on the phone only need receipts, not another transfer.")
        #expect(pages == 64)
        #expect(try await watch.queueSummary(sessionID: m.sessionID).pendingChunkCount == 0)
        #expect(try await phone.pendingReceipts().isEmpty)
        #expect(try await watch.pendingFileReplays().isEmpty)
        for index in [0, 251, 502] {
            let envelope = encoded[index].envelope
            let lease = try await phone.acquireAudioLease(chunkID: envelope.manifest.chunkID)
            #expect(try ContentHash.sha256(fileAt: lease.audioURL) == envelope.manifest.audioSHA256)
            await phone.releaseAudioLease(id: lease.id)
        }
    }

    @Test(arguments: [false, true])
    func missingPhoneFileRetransmitsPreservedWatchAudioAndClosesReceiptLoop(removeManifest: Bool) async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        var writer = try PCM16SegmentWriter(directory: fixture.root.appendingPathComponent("encoder"),
            sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID, sourceBuild: "reconciliation-tests",
            sourceKind: .fixture, sampleRate: 16_000, targetFrames: 16_000,
            wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        let encoded = try writer.append((0..<16_000).map { Int16($0 % 200 - 100) })
        _ = try writer.finish()
        let full = try #require(encoded.first)
        let watch = try fixture.store()
        let chunk = try await watch.sealChunk(audioAt: full.audioURL, envelope: full.envelope)
        let phone = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverID)
        try await watch.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: phone.libraryInstanceID)
        guard case .accepted(let originalReceipt) = try await phone.commitReceivedChunk(deliver(chunk, to: phone, root: fixture.root)) else {
            Issue.record("Expected first durable phone receipt"); return
        }
        // Drop that receipt, then replace a queued successful response after the phone file disappears.
        let request = try #require(await watch.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID))
        let previousSuccess = try await phone.receiveReconcileRequest(request)
        #expect(previousSuccess.results.map(\.state) == [.received(originalReceipt)])
        let lease = try await phone.acquireAudioLease(chunkID: chunk.envelope.manifest.chunkID)
        await phone.releaseAudioLease(id: lease.id)
        let missingFile = removeManifest ? lease.audioURL.appendingPathExtension("manifest.json") : lease.audioURL
        try FileManager.default.removeItem(at: missingFile)
        let pending = try await phone.pendingReconcileResponses()
        let missing = try #require(pending.first)
        #expect(missing.messageID != previousSuccess.messageID && missing.results.map(\.state) == [.missing])
        let result = try await watch.applyReconciliationResponse(missing)
        #expect(result.retryChunkIDs == [chunk.envelope.manifest.chunkID] && result.receiptApplications.isEmpty)
        #expect(try await watch.cleanupAcknowledgedChunks().isEmpty)

        let restartedWatch = try fixture.store()
        #expect(try await restartedWatch.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == nil)
        let replay = try await restartedWatch.pendingFileReplays()
        #expect(replay == [chunk.envelope.manifest.chunkID])
        try await restartedWatch.fileReplaysScheduled(replay)
        await #expect(throws: RecordingError.receiptNeedsReconciliation(chunk.envelope.manifest.chunkID)) {
            try await restartedWatch.applyReceipt(originalReceipt)
        }
        #expect(try await restartedWatch.cleanupAcknowledgedChunks().isEmpty)
        let page = try await restartedWatch.pendingChunkBatch(after: 0)
        let resend = try #require(page.first).chunk
        guard case .restored(let repairedReceipt) = try await phone.commitReceivedChunk(deliver(resend, to: phone, root: fixture.root)) else {
            Issue.record("Matching preserved original must repair the missing phone file"); return
        }
        #expect(repairedReceipt == originalReceipt)
        let repairedRequest = try #require(await restartedWatch.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID, beginNewRound: true))
        let repairedResponse = try await phone.receiveReconcileRequest(repairedRequest)
        #expect(repairedResponse.results.map(\.state) == [.received(originalReceipt)])
        let confirmation = try await restartedWatch.applyReconciliationResponse(repairedResponse)
        let applied = try #require(confirmation.receiptApplications.first)
        #expect(try await restartedWatch.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == repairedReceipt)
        #expect(try await restartedWatch.cleanupAcknowledgedChunks() == [chunk.envelope.manifest.chunkID])
        #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
        #expect(try await restartedWatch.applyReconciliationResponse(previousSuccess).ignored)

        // Drop ReceiptApplied too. Both stores retain enough identity to resend the same acknowledgment.
        let reopenedWatch = try fixture.store()
        let reopenedPhone = try ArchiveStore(rootURL: phone.rootURL, receiverDeviceID: fixture.receiverID)
        let finalRequest = try #require(await reopenedWatch.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID, beginNewRound: true))
        let finalResponse = try await reopenedPhone.receiveReconcileRequest(finalRequest)
        let final = try await reopenedWatch.applyReconciliationResponse(finalResponse)
        #expect(final.receiptApplications == [applied])
        try await reopenedPhone.applyReceipt(applied)
        try await reopenedPhone.applyReceipt(applied)
        #expect(try await reopenedPhone.pendingReceipts().isEmpty)
        #expect(try await reopenedWatch.pendingChunks().isEmpty)
        #expect(try await reopenedWatch.pendingFileReplays().isEmpty)
        let restoredLease = try await reopenedPhone.acquireAudioLease(chunkID: chunk.envelope.manifest.chunkID)
        #expect(try ContentHash.sha256(fileAt: restoredLease.audioURL) == chunk.envelope.manifest.audioSHA256)
        await reopenedPhone.releaseAudioLease(id: restoredLease.id)
        #expect(try await reopenedWatch.chunk(id: chunk.envelope.manifest.chunkID)?.state == .removed)
    }

    private func deliver(_ chunk: RecordedChunk, to phone: ArchiveStore, root: URL) throws -> InboxItem {
        let incoming = root.appendingPathComponent("delivery-\(UUID())")
        try FileManager.default.copyItem(at: chunk.audioURL, to: incoming)
        return try phone.inbox.preserve(fileURL: incoming, envelope: chunk.envelope)
    }
}
