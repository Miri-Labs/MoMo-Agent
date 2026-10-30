import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveExportTests {
    @Test func partialExportCopiesOnlyAvailableBytesAndDescribesExpiredMissingAndUnreceivedRanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.transcribe(store)
        for receipt in try await store.pendingReceipts() { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        #expect(try await store.expireAudio(olderThan: .distantFuture, replayFloors: [fixture.epochID: 1600]).count == 1)

        // [1600, 3200) has never arrived. The third file disappears before reconciliation.
        let available = try fixture.envelope(startFrame: 3200, sequence: 2)
        let missing = try fixture.envelope(startFrame: 4800, sequence: 3)
        let document = first
        for envelope in [available, missing] {
            guard case .accepted = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                Issue.record("The partial export fixture must receive both later chunks.")
                return
            }
        }
        // The legacy job queue correctly waits for the missing predecessor. Export the already
        // completed first transcript plus available audio; do not invent recognition across the gap.
        #expect(try await store.claimAnalysisJob(configurationHash: "model-v1") == nil)
        let missingLease = try await store.acquireAudioLease(chunkID: missing.manifest.chunkID)
        await store.releaseAudioLease(id: missingLease.id)
        try FileManager.default.removeItem(at: missingLease.audioURL)
        try await store.projectPendingDocuments()
        let ticket = try await store.beginRecordingExport(sessionID: fixture.sessionID,
            expectedGeneration: document.generation, expectedTranscriptVersion: document.version, content: .audioAndTranscript)
        guard case .recording(let exportedSource) = ticket.export.source else {
            Issue.record("Expected recording export")
            return
        }
        #expect(exportedSource.exportedAudioChunkIDs == [available.manifest.chunkID])
        #expect(Set(await store.audioLeases.values) == [available.manifest.chunkID])
        try ExportFileCopy.stage(ticket)
        try await store.validateExportSource(ticket.export)
        let files = ticket.export.fileURLs.filter { $0.pathExtension == "wav" }
        #expect(files.count == 1)
        #expect(try Data(contentsOf: #require(files.first)) == fixture.audio)
        let index = try #require(JSONSerialization.jsonObject(with: ticket.index) as? [String: Any])
        let chunks = try #require(index["chunks"] as? [[String: Any]])
        #expect(chunks.count == 3)
        #expect(chunks[0]["audioOmission"] as? String == "expired")
        #expect(chunks[0]["audioFilename"] == nil)
        #expect(chunks[1]["audioOmission"] == nil)
        #expect(chunks[1]["audioFilename"] as? String == files.first?.lastPathComponent)
        #expect(chunks[2]["audioOmission"] as? String == "missing_unexpected")
        #expect(chunks[2]["audioFilename"] == nil)
        let epochs = try #require(index["epochs"] as? [[String: Any]])
        let epoch = try #require(epochs.first)
        let gaps = try #require(epoch["notReceived"] as? [[String: Any]])
        #expect(gaps.count == 1)
        #expect(gaps[0]["start"] as? Int == 1600 && gaps[0]["count"] as? Int == 1600)
        #expect(epoch["unknownTailFromFrame"] as? Int == 6400)
        let transcript = try WireJSON.decode(TranscriptDocument.self,
            from: Data(contentsOf: ticket.export.directory.appendingPathComponent("transcript.json")))
        #expect(transcript.spans == document.spans, "Omitting original audio must not omit its transcript.")
        await store.releaseExportLeases(ticket)
        #expect(await store.audioLeases.isEmpty)
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: document.spans)
        await #expect(throws: ArchiveExportError.sourceChanged) { try await store.validateExportSource(ticket.export) }
        try await store.removeExport(ticket.export)
    }

    @Test func partialExportLeaseProtectsRemainingAudioAndDeletionStillBlocksSharing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.transcribe(store)
        for receipt in try await store.pendingReceipts() { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        _ = try await store.expireAudio(olderThan: .distantFuture, replayFloors: [fixture.epochID: 1600])
        let available = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(available, to: store))
        let ticket = try await store.beginRecordingExport(sessionID: fixture.sessionID,
            expectedGeneration: first.generation, expectedTranscriptVersion: first.version, content: .audio)
        let input = try #require(ticket.inputs.first)
        _ = try await store.deleteSession(id: fixture.sessionID)
        try await store.cleanDeletedFiles()
        #expect(FileManager.default.fileExists(atPath: input.source.path))
        try ExportFileCopy.stage(ticket)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) { try await store.validateExportSource(ticket.export) }
        try await store.removeExport(ticket.export)
        await store.releaseExportLeases(ticket)
        try await store.cleanDeletedFiles()
        #expect(!FileManager.default.fileExists(atPath: input.source.path))
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func allMissingAudioRejectsExportAndPartialAvailabilityDoesNotHideCorruption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let lease = try await store.acquireAudioLease(chunkID: document.spans[0].chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        await #expect(throws: ArchiveExportError.audioUnavailable) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        let corrupt = try await store.acquireAudioLease(chunkID: second.manifest.chunkID)
        await store.releaseAudioLease(id: corrupt.id)
        try Data(repeating: 7, count: fixture.audio.count).write(to: corrupt.audioURL)
        await #expect(throws: ArchiveError.checksumMismatch) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        #expect(await store.audioLeases.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: await store.exportRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func multiPartSnapshotPreservesBytesMetadataAndProtectionThenCleansIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let document = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        try await store.projectPendingDocuments()
        let artifact = try await store.prepareRecordingExport(sessionID: fixture.sessionID,
            expectedGeneration: document.generation, expectedTranscriptVersion: document.version, content: .audioAndTranscript)
        #expect(artifact.fileURLs.count == 6)
        let audio = artifact.fileURLs.filter { $0.pathExtension == "wav" }
        #expect(audio.count == 2)
        for url in audio { #expect(try Data(contentsOf: url) == fixture.audio) }
        let exportedDocument = try WireJSON.decode(TranscriptDocument.self,
            from: Data(contentsOf: artifact.directory.appendingPathComponent("transcript.json")))
        #expect(exportedDocument.version == document.version && exportedDocument.spans == document.spans)
        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: artifact.directory.appendingPathComponent("recording.json"))) as? [String: Any])
        #expect(index["scope"] as? String == "received_on_phone_snapshot")
        #expect((index["chunks"] as? [Any])?.count == 2)
        #expect(await store.audioLeases.isEmpty)
        #if canImport(Darwin)
        for url in artifact.fileURLs {
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #endif
        try await store.removeExport(artifact)
        try await store.removeExport(artifact)
        #expect(!FileManager.default.fileExists(atPath: artifact.directory.path))
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == document.version)
    }

    @Test func leaseProtectsCopyAndDeletionInvalidatesSnapshotBeforeSharing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        for receipt in try await store.pendingReceipts() { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        let ticket = try await store.beginRecordingExport(sessionID: fixture.sessionID,
            expectedGeneration: document.generation, expectedTranscriptVersion: document.version, content: .audio)
        let chunk = try #require(ticket.inputs.first)
        #expect(try await store.expireAudio(olderThan: .distantFuture, replayFloors: [fixture.epochID: 1600]).isEmpty)
        _ = try await store.deleteSession(id: fixture.sessionID)
        try await store.cleanDeletedFiles()
        #expect(FileManager.default.fileExists(atPath: chunk.source.path))
        try ExportFileCopy.stage(ticket)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) { try await store.validateExportSource(ticket.export) }
        try await store.removeExport(ticket.export)
        await store.releaseExportLeases(ticket)
        try await store.cleanDeletedFiles()
        #expect(!FileManager.default.fileExists(atPath: chunk.source.path))
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func expiredAudioRejectsAudioExportButTextRemainsExportable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        for receipt in try await store.pendingReceipts() { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        #expect(try await store.expireAudio(olderThan: .distantFuture, replayFloors: [fixture.epochID: 1600]).count == 1)
        await #expect(throws: ArchiveExportError.audioUnavailable) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        let text = try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
            expectedTranscriptVersion: document.version, content: .transcript)
        #expect(text.fileURLs.allSatisfy { $0.pathExtension != "wav" })
        try await store.removeExport(text)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func sourceRevisionAndNewChunkRejectPreparedSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let artifact = try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
            expectedTranscriptVersion: document.version, content: .audio)
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(startFrame: 1600, sequence: 1), to: store))
        await #expect(throws: ArchiveExportError.sourceChanged) { try await store.validateExportSource(artifact) }
        _ = try await store.reviseTranscript(sessionID: document.sessionID, expectedVersion: document.version, spans: document.spans)
        await #expect(throws: ArchiveExportError.sourceChanged) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        try await store.removeExport(artifact)
    }

    @Test func corruptCopyFailsHashAndCleansTemporaryFilesAndLeases() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let lease = try await store.acquireAudioLease(chunkID: document.spans[0].chunkID)
        await store.releaseAudioLease(id: lease.id)
        try Data(repeating: 7, count: fixture.audio.count).write(to: lease.audioURL)
        await #expect(throws: ArchiveError.checksumMismatch) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        #expect(await store.audioLeases.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: await store.exportRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func cancelledCopyChecksBetweenBoundedBuffersAndCancelledPreparationLeavesNoLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 5, count: ExportFileCopy.bufferSize * 4)
        let source = fixture.root.appendingPathComponent("large-audio")
        let destination = fixture.root.appendingPathComponent("partial")
        try bytes.write(to: source)
        let input = ExportFileInput(source: source, filename: "partial", byteCount: Int64(bytes.count), sha256: ContentHash.sha256(bytes))
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ExportFileCopy.copy(input, to: destination) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
        }
        #expect(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == ExportFileCopy.bufferSize)
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func coldStartCleansAbandonedSnapshotsAndRejectsSymbolicLinkRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let artifact = try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
            expectedTranscriptVersion: document.version, content: .audio)
        let reopened = try fixture.store()
        try await reopened.removeAbandonedExports()
        #expect(!FileManager.default.fileExists(atPath: artifact.directory.path))
        let exports = await store.exportRoot
        try FileManager.default.removeItem(at: exports)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: exports, withDestinationURL: outside)
        await #expect(throws: ArchiveExportError.unsafeTemporaryPath) {
            try await store.prepareRecordingExport(sessionID: fixture.sessionID, expectedGeneration: document.generation,
                expectedTranscriptVersion: document.version, content: .audio)
        }
        #expect(await store.audioLeases.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).isEmpty)
    }
}
