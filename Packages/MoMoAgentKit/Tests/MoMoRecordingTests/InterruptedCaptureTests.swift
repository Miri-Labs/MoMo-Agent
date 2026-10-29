import Foundation
import Testing
import MoMoArchive
import MoMoContracts
@testable import MoMoRecording

private enum InterruptedWriter: Error { case stopped }

@Suite(.serialized)
struct InterruptedCaptureTests {
    private let fingerprint = ContentHash.sha256(Data("interrupted-capture-test".utf8))

    @Test(arguments: [CaptureIntent.recording, .paused])
    func processExitEndsTheSessionAndRetainsItsAudioForSync(intent: CaptureIntent) async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let watch = try fixture.store()
        try await watch.saveIntent(intent, sessionID: m.sessionID)
        try await watch.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        let chunk = try await watch.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        if intent == .paused {
            try await watch.recordEpochEnded(CaptureEpochEnded(sessionID: m.sessionID, epochID: m.epochID,
                sourceDeviceID: m.sourceDeviceID, endFrame: m.frames.end, reason: .paused))
        }
        let previousDuration = try await watch.sealedDuration(sessionID: m.sessionID)
        let reopened = try fixture.store()
        let recovered = try await reopened.recoverInterruptedEpochs()
        #expect(recovered.count == (intent == .recording ? 1 : 0))
        #expect(try await reopened.latestActiveSession() == nil)
        #expect(try await reopened.intent(sessionID: m.sessionID) == .stopped)
        #expect(try await reopened.isCaptureEpochOpen(m.epochID) == false)
        #expect(try await reopened.sealedDuration(sessionID: m.sessionID) == previousDuration)
        #expect(try await reopened.pendingChunks().map(\.envelope) == [chunk.envelope])
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == m.audioSHA256)
        let events = try await reopened.pendingCaptureEvents()
        #expect(try await reopened.recoverInterruptedEpochs().isEmpty)
        #expect(try await reopened.pendingCaptureEvents() == events)

        let nextSession = UUID()
        try await reopened.saveIntent(.recording, sessionID: nextSession)
        #expect(try await reopened.sealedDuration(sessionID: nextSession) == 0)
        #expect(try await reopened.pendingChunkCount() == 1)
    }

    @Test(arguments: [false, true])
    func damagedTailKeepsItsMarkWithoutInventingAnEpochEnd(interruptionFirst: Bool) async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let watch = try fixture.store()
        try await watch.saveIntent(.recording, sessionID: m.sessionID)
        try await watch.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        let writer = try AACSegmentWriter(directory: fixture.root.appendingPathComponent("live"),
            sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests",
            sourceKind: .fixture, inputSampleRate: 16_000, targetSeconds: 1,
            wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        var chunks: [EncodedChunk] = []
        for _ in 0..<4 { chunks += try writer.append(Array(repeating: 0.1, count: 4_000)) }
        let sealed = try #require(chunks.first)
        _ = try await watch.sealChunk(audioAt: sealed.audioURL, envelope: sealed.envelope)
        _ = try writer.append(Array(repeating: 0.2, count: 4_000))
        let mark = try CaptureMark(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sourceFrame: 20_000)
        try await watch.recordMark(mark)

        let spool = fixture.root.appendingPathComponent("snapshot")
        let epoch = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        try FileManager.default.createDirectory(at: epoch, withIntermediateDirectories: true)
        var snapshot: URL?
        writer.sealCheckpoint = { step, audio in
            if case .beforeContainerClose = step {
                let copy = epoch.appendingPathComponent(audio.lastPathComponent)
                try FileManager.default.copyItem(at: audio, to: copy)
                try FileManager.default.copyItem(at: SealedCaptureSpool.draftURL(for: audio), to: SealedCaptureSpool.draftURL(for: copy))
                snapshot = copy
                throw InterruptedWriter.stopped
            }
        }
        #expect(throws: InterruptedWriter.self) { try writer.finish() }
        let damaged = try #require(snapshot)
        let originalBytes = try Data(contentsOf: damaged)
        let reopenedWatch = try fixture.store()
        _ = try await reopenedWatch.recover()
        let recoveredSpool = try await CaptureSpool.recover(directory: spool, store: reopenedWatch)
        #expect(recoveredSpool.recovered.isEmpty)
        let repair = spool.appendingPathComponent("Repair").appendingPathComponent(m.sessionID.uuidString)
            .appendingPathComponent(m.epochID.uuidString).appendingPathComponent(damaged.lastPathComponent)
        #expect(try Data(contentsOf: repair) == originalBytes)
        let interruptions = try await reopenedWatch.recoverInterruptedEpochs()
        let interruption = try #require(interruptions.first)
        #expect(interruption.sealedThroughFrame == 16_000 && interruption.lastObservedFrame == 20_000)
        #expect(try await reopenedWatch.recoverInterruptedEpochs().isEmpty)
        #expect(try await reopenedWatch.pendingCaptureEvents().contains(.captureMark(mark)))
        #expect(try await reopenedWatch.pendingCaptureEvents().contains(.epochInterrupted(interruption)))
        #expect(try await reopenedWatch.sealedDuration(sessionID: m.sessionID) == 1)

        let phone = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverID)
        if interruptionFirst { try await phone.receiveEpochInterruption(interruption) }
        try await phone.receiveMark(mark)
        try await phone.receiveEpochInterruption(interruption)
        try await phone.receiveMark(mark)
        try await deliver(sealed, to: phone, root: fixture.root)
        let coverage = try await phone.recordingCoverage(sessionID: m.sessionID, configurationFingerprint: fingerprint)
        let received = try #require(coverage.epochs.first)
        #expect(received.closedAtFrame == nil && received.unknownTailFromFrame == 20_000)
        #expect(received.received == [try FrameRange(start: 0, count: 16_000)])
        #expect(received.notReceived == [try FrameRange(start: 16_000, count: 4_000)])
        #expect(received.noSpeech.isEmpty && received.transcribed.isEmpty)
        #expect(received.marks.count == 1 && received.marks.first?.location == .unknownTail)

        let candidate = try await phone.claimEpochAnalysis(configurationFingerprint: fingerprint)
        let ticket = try #require(candidate)
        #expect(ticket.epochClosed && ticket.epochID == m.epochID)
        try await finishAnalysis(ticket, phone: phone)
        await #expect(throws: ArchiveError.conflictingEpoch(m.epochID)) {
            try await phone.receiveEpochEnd(CaptureEpochEnded(sessionID: m.sessionID, epochID: m.epochID,
                sourceDeviceID: m.sourceDeviceID, endFrame: 16_000, reason: .stopped))
        }

        let nextEpoch = UUID()
        let next = try pcmChunks(fixture: fixture, epochID: nextEpoch, frameCounts: 1, sampleRate: 16_000)[0]
        try await deliver(next, to: phone, root: fixture.root)
        try await phone.receiveEpochEnd(CaptureEpochEnded(sessionID: m.sessionID, epochID: nextEpoch,
            sourceDeviceID: m.sourceDeviceID, endFrame: next.envelope.manifest.frames.end, reason: .stopped))
        let nextCandidate = try await phone.claimEpochAnalysis(configurationFingerprint: fingerprint)
        let nextTicket = try #require(nextCandidate)
        #expect(nextTicket.epochID == nextEpoch && nextTicket.epochClosed)
        try await phone.cancelEpochAnalysis(ticket: nextTicket)
        let reopenedPhone = try ArchiveStore(rootURL: phone.rootURL, receiverDeviceID: fixture.receiverID)
        let restored = try await reopenedPhone.recordingCoverage(sessionID: m.sessionID, configurationFingerprint: fingerprint)
        #expect(restored.epochs.first { $0.epochID == m.epochID }?.unknownTailFromFrame == 20_000)
        #expect(try await reopenedPhone.marks(sessionID: m.sessionID) == [mark])
    }

    @Test func interruptedPrefixWaitsForMissingFilesAndAcceptsALaterRecoveredTail() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let chunks = try pcmChunks(fixture: fixture, epochID: m.epochID, frameCounts: 3, sampleRate: 16_000)
        let phone = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverID)
        let interruption = try CaptureEpochInterrupted(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sealedThroughFrame: 32_000, lastObservedFrame: 40_000, reason: .failed)
        try await phone.receiveEpochInterruption(interruption)
        try await deliver(chunks[1], to: phone, root: fixture.root)
        #expect(try await phone.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil)
        try await deliver(chunks[0], to: phone, root: fixture.root)
        let firstCandidate = try await phone.claimEpochAnalysis(configurationFingerprint: fingerprint)
        let first = try #require(firstCandidate)
        #expect(first.epochClosed && first.inputs.count == 2)
        try await finishAnalysis(first, phone: phone)
        try await deliver(chunks[2], to: phone, root: fixture.root)
        let tailCandidate = try await phone.claimEpochAnalysis(configurationFingerprint: fingerprint)
        let tail = try #require(tailCandidate)
        #expect(tail.epochClosed && tail.inputs.count == 1 && tail.checkpoint?.sourceFrame == 32_000)
        try await finishAnalysis(tail, phone: phone)
        let result = try await phone.recordingCoverage(sessionID: m.sessionID, configurationFingerprint: fingerprint)
        #expect(result.epochs.first?.closedAtFrame == nil && result.epochs.first?.unknownTailFromFrame == 48_000)
        #expect(result.epochs.first?.noSpeech.isEmpty == true)
        #expect(result.receivedDuration == 3)
    }

    @Test func confirmedEndStillRejectsMarksAndInterruptionBoundsBeyondIt() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let phone = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverID)
        try await phone.receiveEpochEnd(CaptureEpochEnded(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, endFrame: 16_000, reason: .interrupted))
        await #expect(throws: ArchiveError.conflictingEpoch(m.epochID)) {
            try await phone.receiveMark(CaptureMark(sessionID: m.sessionID, epochID: m.epochID,
                sourceDeviceID: m.sourceDeviceID, sourceFrame: 20_000))
        }
        await #expect(throws: ArchiveError.conflictingEpoch(m.epochID)) {
            try await phone.receiveEpochInterruption(CaptureEpochInterrupted(sessionID: m.sessionID, epochID: m.epochID,
                sourceDeviceID: m.sourceDeviceID, sealedThroughFrame: 16_000, lastObservedFrame: 20_000, reason: .failed))
        }
        let result = try await phone.recordingCoverage(sessionID: m.sessionID, configurationFingerprint: nil)
        #expect(result.epochs.first?.closedAtFrame == 16_000 && result.epochs.first?.unknownTailFromFrame == nil)
    }

    @Test func restartDurationKeepsAcknowledgedEpochsAndExcludesUnsealedMarks() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let first = try pcmChunks(fixture: fixture, epochID: m.epochID, frameCounts: 1, sampleRate: 16_000)[0]
        let nextEpoch = UUID()
        let second = try pcmChunks(fixture: fixture, epochID: nextEpoch, frameCounts: 1, sampleRate: 8_000)[0]
        let watch = try fixture.store()
        try await watch.saveIntent(.paused, sessionID: m.sessionID)
        try await watch.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        for chunk in [first, second, first] { _ = try await watch.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope) }
        _ = try await watch.applyReceipt(Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            chunkID: first.envelope.manifest.chunkID, audioSHA256: first.envelope.manifest.audioSHA256,
            manifestSHA256: first.envelope.manifestSHA256))
        #expect(try await watch.cleanupAcknowledgedChunks() == [first.envelope.manifest.chunkID])
        try await watch.recordMark(CaptureMark(sessionID: m.sessionID, epochID: nextEpoch,
            sourceDeviceID: m.sourceDeviceID, sourceFrame: 80_000))
        let reopened = try fixture.store()
        #expect(try await reopened.latestActiveSession()?.intent == .paused)
        #expect(try await reopened.sealedDuration(sessionID: m.sessionID) == 2)
        let deletion = try DeleteSession(sessionID: m.sessionID, generation: 1)
        try await reopened.prepareDeletion(deletion, deviceID: m.sourceDeviceID)
        #expect(try await reopened.sealedDuration(sessionID: m.sessionID) == 0)
    }

    @Test func writerFailureRecordsObservedLowerBoundAndReplaysTheSameEvent() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let watch = try fixture.store()
        try await watch.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        _ = try await watch.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        try await watch.recordMark(CaptureMark(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sourceFrame: 320))
        let first = try await watch.recordEpochInterruption(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, lastObservedFrame: 480, reason: .failed)
        let reopened = try fixture.store()
        let retry = try await reopened.recordEpochInterruption(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, lastObservedFrame: 480, reason: .failed)
        #expect(first == retry && first.sealedThroughFrame == 160 && first.lastObservedFrame == 480)
        #expect(try await reopened.recoverInterruptedEpochs().isEmpty)
    }

    private func pcmChunks(fixture: RecordingFixture, epochID: UUID, frameCounts: Int, sampleRate: Int) throws -> [EncodedChunk] {
        let m = fixture.envelope.manifest
        var writer = try PCM16SegmentWriter(directory: fixture.root.appendingPathComponent("pcm-\(epochID)"),
            sessionID: m.sessionID, epochID: epochID, sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests",
            sourceKind: .fixture, sampleRate: sampleRate, targetFrames: sampleRate,
            wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        let chunks = try writer.append(Array(repeating: Int16(100), count: sampleRate * frameCounts))
        _ = try writer.finish()
        return chunks
    }

    private func deliver(_ chunk: EncodedChunk, to phone: ArchiveStore, root: URL) async throws {
        let temporary = root.appendingPathComponent("incoming-\(UUID())")
        try FileManager.default.copyItem(at: chunk.audioURL, to: temporary)
        let item = try phone.inbox.preserve(fileURL: temporary, envelope: chunk.envelope)
        let result = try await phone.commitReceivedChunk(item)
        guard case .accepted(let receipt) = result else { Issue.record("Expected a first durable receipt"); return }
        #expect(receipt.matches(chunk.envelope))
    }

    private func finishAnalysis(_ ticket: EpochAnalysisTicket, phone: ArchiveStore) async throws {
        let first = try #require(ticket.inputs.first)
        let last = try #require(ticket.inputs.last)
        let range = try FrameRange(start: first.envelope.manifest.frames.start,
            count: last.envelope.manifest.frames.end - first.envelope.manifest.frames.start)
        // Exercise queue completion only. No recognition or VAD result is claimed by this fixture.
        try await phone.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [],
            checkpoint: ArchiveCheckpoint(sessionID: ticket.sessionID, epochID: ticket.epochID,
                sourceFrame: range.end, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
    }
}
