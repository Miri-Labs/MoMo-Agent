import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveStoreTests {
    @Test(arguments: ["Library/Caches/com.apple.dyld", "Documents/Inbox"])
    func startupLeavesSystemManagedDirectoriesUntouched(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("phone")
        let cache = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("system-managed-file")
        let original = Data("system-managed-cache".utf8)
        try original.write(to: file)
        #if os(macOS)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        #endif
        _ = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        #expect(try Data(contentsOf: file) == original)
        #if os(macOS)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.immutable] as? Bool == true)
        #endif
    }

    @Test func retentionPreferencePinAndAudioStatesPersist() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        #expect(try await store.audioRetentionPolicy() == .days(7))
        try await store.setAudioRetentionPolicy(.days(30))
        let reopened = try fixture.store()
        #expect(try await reopened.audioRetentionPolicy() == .days(30))
        await #expect(throws: ArchiveError.invalidQuery) { try await store.setAudioRetentionPolicy(.days(0)) }
        let first = try fixture.envelope()
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(first, to: store)) else { Issue.record("Expected accepted"); return }
        try await store.applyReceipt(ReceiptApplied(receipt: receipt))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        try await store.setKeepAudio(sessionID: fixture.sessionID, keep: true)
        #expect(try await store.recordings().first?.keepAudio == true)
        #expect(try await store.recordings().first?.audioState == .available)
        let future = first.manifest.sealedAt.addingTimeInterval(31 * 86_400)
        let floors = [fixture.epochID: first.manifest.frames.end]
        #expect(try await store.applyRetention(now: future, replayFloors: floors).isEmpty)
        try await store.setKeepAudio(sessionID: fixture.sessionID, keep: false)
        #expect(try await store.applyRetention(now: future, replayFloors: [:]).isEmpty)
        #expect(try await store.applyRetention(now: future, replayFloors: floors) == [first.manifest.chunkID])
        #expect(try await store.recordings().first?.audioState == .expired)
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        #expect(try await store.recordings().first?.audioState == .partiallyExpired)
        let lease = try await store.acquireAudioLease(chunkID: second.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        await #expect(throws: ArchiveError.missingRecording(second.manifest.chunkID)) { try await store.acquireAudioLease(chunkID: second.manifest.chunkID) }
        #expect(try await store.recordings().first?.audioState == .missingUnexpected)
    }

    @Test func archiveFilesApplyProtectionAndBackupPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let lease = try await store.acquireAudioLease(chunkID: document.spans[0].chunkID)
        let markdown = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        let support = store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent")
        let paths = [store.rootURL.appendingPathComponent("Library"), store.rootURL.appendingPathComponent("Documents"),
                     store.rootURL.appendingPathComponent("tmp"), support, store.inbox.rootURL,
                     support.appendingPathComponent("archive.sqlite"), support.appendingPathComponent("archive.sqlite-wal"),
                     support.appendingPathComponent("archive.sqlite-shm"), lease.audioURL,
                     lease.audioURL.appendingPathExtension("manifest.json"), markdown]
        for url in paths {
            #expect(FileManager.default.fileExists(atPath: url.path))
            #if canImport(Darwin)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            #endif
            #if os(iOS)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? String == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            #endif
        }
        await store.releaseAudioLease(id: lease.id)
    }

    @Test func receiveIsAtomicAndDuplicateSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(item) else { Issue.record("Expected accepted"); return }
        let reopened = try fixture.store()
        #expect(try await reopened.pendingReceipts() == [receipt])
        let duplicate = try fixture.deliver(envelope, to: reopened)
        guard case .duplicate(let resent) = try await reopened.commitReceivedChunk(duplicate) else { Issue.record("Expected duplicate"); return }
        #expect(resent == receipt)
        #expect(try await reopened.recordings().count == 1)
        #expect(try await reopened.claimAnalysisJob(configurationHash: "model-v1") != nil)
        #expect(try await reopened.claimAnalysisJob(configurationHash: "model-v1") == nil)
    }

    @Test func corruptAudioNeverReceivesPositiveReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store, audio: Data(repeating: 1, count: fixture.audio.count))
        await #expect(throws: ArchiveError.checksumMismatch) { try await store.commitReceivedChunk(item) }
        #expect(try await store.pendingReceipts().isEmpty)
        #expect(try await store.recordings().isEmpty)
    }

    @Test func sameIdentityDifferentContentDoesNotOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let other = Data(repeating: 7, count: fixture.audio.count)
        let conflict = try fixture.envelope(chunkID: envelope.manifest.chunkID, audio: other)
        await #expect(throws: ArchiveError.conflictingChunk(envelope.manifest.chunkID)) {
            try await store.commitReceivedChunk(fixture.deliver(conflict, to: store, audio: other))
        }
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        #expect(try Data(contentsOf: ticket.audioURL) == fixture.audio)
    }

    @Test func deletionRejectsLateAnalysisAndFilesAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let deletion = try await store.deleteSession(id: fixture.sessionID)
        #expect(deletion.generation == 1)
        await #expect(throws: ArchiveError.staleAttempt) { try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket)) }
        let reopened = try fixture.store()
        guard case .deleted = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else { Issue.record("Expected deleted"); return }
        #expect(try await reopened.recordings().isEmpty)
        #expect(try await reopened.pendingReceipts().isEmpty)
    }

    @Test func recoveryInvalidatesOldAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let old = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        try await store.recoverInterruptedJobs()
        let current = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        #expect(current.attemptID != old.attemptID)
        await #expect(throws: ArchiveError.staleAttempt) { try await store.commitTranscript(ticket: old, spans: fixture.spans(old)) }
        _ = try await store.commitTranscript(ticket: current, spans: fixture.spans(current))
    }

    @Test func chineseSearchProjectionAndPlanIdempotency() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let hits = try await store.searchTranscripts(query: "下周安排")
        #expect(hits.count == 1)
        #expect(hits[0].source.transcriptVersion == document.version)
        await #expect(throws: ArchiveError.projectionPending) { try await store.transcriptFileURL(sessionID: fixture.sessionID) }
        try await store.projectPendingDocuments()
        let file = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("下周安排"))
        let operation = UUID()
        let first = try await store.savePlan(operationID: operation, title: "安排", body: "周一确认时间。", sources: [hits[0].source])
        let reopened = try fixture.store()
        let duplicate = try await reopened.savePlan(operationID: operation, title: "安排", body: "周一确认时间。", sources: [hits[0].source])
        #expect(first.id == duplicate.id)
        await #expect(throws: ArchiveError.operationConflict(operation)) {
            try await reopened.savePlan(operationID: operation, title: "安排", body: "不同内容", sources: [hits[0].source])
        }
        #expect(try await reopened.plans().count == 1)
    }

    @Test func deletedProjectionIsNotSilentlyRecreated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let file = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: ArchiveError.projectionConflict) { try await store.transcriptFileURL(sessionID: fixture.sessionID) }
        try await store.projectPendingDocuments()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func validHashDoesNotMakeMalformedContainerAcceptable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let malformed = Data(repeating: 0, count: 3244)
        let envelope = try fixture.envelope(audio: malformed)
        await #expect(throws: (any Error).self) {
            try await store.commitReceivedChunk(fixture.deliver(envelope, to: store, audio: malformed))
        }
        #expect(try await store.pendingReceipts().isEmpty)
    }

    @Test func matchingRetransmissionRepairsMissingStoredAudioBeforeAcknowledgement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        try FileManager.default.removeItem(at: ticket.audioURL)
        #expect(try await store.pendingReceipts().isEmpty)
        let replacement = try fixture.deliver(envelope, to: store)
        guard case .restored = try await store.commitReceivedChunk(replacement) else { Issue.record("Expected restored original"); return }
        #expect(try await store.pendingReceipts().count == 1)
        #expect(try ContentHash.sha256(fileAt: ticket.audioURL) == envelope.manifest.audioSHA256)
    }

    @Test func audioMovedBeforeDatabaseCommitRecoversFromInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store)
        let relative = await store.recordingDirectory(manifest: envelope.manifest)
        let audioDirectory = store.rootURL.appendingPathComponent(relative).appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item.directoryURL.appendingPathComponent("audio"), to: audioDirectory.appendingPathComponent(envelope.manifest.chunkID.uuidString + ".wav"))
        let reopened = try fixture.store()
        let recovered = try await reopened.processInbox()
        #expect(recovered.count == 1)
        guard case .accepted = try recovered[0].result.get() else { Issue.record("Expected recovered acceptance"); return }
        #expect(try await reopened.pendingReceipts().count == 1)
        #expect(try await reopened.recordings().count == 1)
    }

    @Test func silentAnalysisHasAnExplicitCompletedState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        #expect(try await store.recordings().first?.transcriptionState == .pending)
        let manifest = envelope.manifest
        try await store.markEpochClosed(epochID: manifest.epochID, endFrame: manifest.frames.end)
        let fingerprint = ContentHash.sha256(Data("silent-model".utf8))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(try await store.recordings().first?.transcriptionState == .processing)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [manifest.frames], checkpoint: ArchiveCheckpoint(sessionID: manifest.sessionID,
                epochID: manifest.epochID, sourceFrame: manifest.frames.end, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
        #expect(try await store.recordings().first?.transcriptionState == .noSpeech)
        #expect(try await store.contextStatus().pendingAnalysisCount == 0)
    }

    @Test func deletionWaitsForNativeAudioLeaseRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: ContentHash.sha256(Data("lease-model".utf8))))
        _ = try await store.deleteSession(id: envelope.manifest.sessionID)
        #expect(try await store.recordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: ticket.inputs[0].audioURL.path))
        try await store.cancelEpochAnalysis(ticket: ticket)
        #expect(!FileManager.default.fileExists(atPath: ticket.inputs[0].audioURL.path))
    }

    @Test func outOfOrderChunksWaitForContiguousCompletedPredecessor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        #expect(try await store.claimAnalysisJob(configurationHash: "model-v1") == nil)
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let one = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        #expect(one.chunkID == first.manifest.chunkID)
        #expect(try await store.claimAnalysisJob(configurationHash: "model-v1") == nil)
        _ = try await store.commitTranscript(ticket: one, spans: fixture.spans(one))
        let two = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        #expect(two.chunkID == second.manifest.chunkID)
    }

    @Test func appendPreservesCitedSpanAndExistingPlan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let old = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let reference = old.source(for: old.spans[0])
        let agent = UUID()
        try await store.registerAgentSources(agentSessionID: agent, sources: [reference])
        let plan = try await store.savePlan(operationID: UUID(), title: "安排", body: "保留原计划", sources: [reference])
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let latest = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        #expect(latest.version > old.version)
        #expect(latest.generation == old.generation)
        let pinned = try await store.transcriptSnapshot(sessionID: old.sessionID, version: old.version)
        #expect(pinned.document.version == old.version && pinned.document.spans == old.spans)
        #expect(pinned.locations.count == old.spans.count)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.transcriptSnapshot(sessionID: old.sessionID, version: latest.version + 1)
        }
        _ = try await store.reconcileDocumentFiles()
        try await store.projectPendingDocuments()
        _ = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        try await store.validateSources([reference])
        #expect(try await store.agentCanResume(agentSessionID: agent))
        #expect(try await store.plans().map(\.id) == [plan.id])
    }

    @Test func revisionBlocksOldAgentHistoryAndInvalidatesPlans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let source = document.source(for: document.spans[0])
        let agent = UUID()
        try await store.registerAgentSources(agentSessionID: agent, sources: [source])
        _ = try await store.savePlan(operationID: UUID(), title: "安排", body: "旧安排", sources: [source])
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: document.spans)
        #expect(try await store.agentCanResume(agentSessionID: agent) == false)
        #expect(try await store.pendingAgentCleanups() == [agent])
        #expect(try await store.plans().isEmpty)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([source]) }
        try await store.markAgentCleanupCompleted(agentSessionID: agent)
        #expect(try await store.agentCanResume(agentSessionID: agent))
    }

    @Test(arguments: [false, true])
    func revisionPreservesOngoingEpoch(revisionDuringRecognition: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("revision-model".utf8))
        func window(_ envelope: ManifestEnvelope) throws -> ArchiveAnalysisWindow {
            let manifest = envelope.manifest
            let modelFrames = try FrameRange(start: 0, count: manifest.frames.count)
            return ArchiveAnalysisWindow(id: ContentHash.sha256(envelope.manifestData),
                sessionID: manifest.sessionID, epochID: manifest.epochID, analysisAnchor: manifest.frames.start,
                coreFrames: manifest.frames, contextFrames: manifest.frames,
                modelCoreFrames: modelFrames, modelContextFrames: modelFrames,
                sources: [ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                    audioSHA256: manifest.audioSHA256, sourceFrames: manifest.frames)], configurationFingerprint: fingerprint)
        }
        func commitAnalysis(_ ticket: EpochAnalysisTicket, for envelope: ManifestEnvelope) async throws {
            try await store.commitAnalysisBatch(ticket: ticket, windows: [window(envelope)],
                analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [],
                checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                    sourceFrame: envelope.manifest.frames.end, configurationFingerprint: fingerprint),
                waitingForMoreAudio: !ticket.epochClosed)
        }

        let first = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let firstAnalysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await commitAnalysis(firstAnalysis, for: first)
        let firstRecognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let original = try await store.commitWindowTranscript(ticket: firstRecognition, text: "周一确认。", rawResult: Data("{}".utf8))
        let firstSpan = try #require(original.spans.first)
        let edited = TranscriptSpan(id: firstSpan.id, chunkID: firstSpan.chunkID, frames: firstSpan.frames,
            text: "周二确认。", speaker: firstSpan.speaker, sourceRanges: firstSpan.sourceRanges)

        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(second, to: store))
        let oldAnalysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let oldRecognition: TranscriptionWindowTicket?
        if revisionDuringRecognition {
            try await commitAnalysis(oldAnalysis, for: second)
            oldRecognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        } else { oldRecognition = nil }
        let revised = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: original.version, spans: [edited])
        #expect(revised.generation == original.generation + 1)

        if let oldRecognition {
            await #expect(throws: ArchiveError.staleAttempt) {
                try await store.commitWindowTranscript(ticket: oldRecognition, text: "迟到结果。", rawResult: Data("{}".utf8))
            }
            try await store.cancelTranscriptionWindow(ticket: oldRecognition)
        } else {
            await #expect(throws: ArchiveError.staleAttempt) { try await commitAnalysis(oldAnalysis, for: second) }
            try await store.cancelEpochAnalysis(ticket: oldAnalysis)
            let resumed = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
            #expect(resumed.expectedGeneration == revised.generation)
            #expect(resumed.checkpoint?.sourceFrame == first.manifest.frames.end)
            try await commitAnalysis(resumed, for: second)
        }
        let resumedRecognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        #expect(resumedRecognition.expectedGeneration == revised.generation)
        #expect(resumedRecognition.window.id == (try window(second)).id)
        _ = try await store.commitWindowTranscript(ticket: resumedRecognition, text: "接着讨论设计。", rawResult: Data("{}".utf8))

        // New audio arrives in the same epoch after the edit and the interrupted work has completed.
        let third = try fixture.envelope(startFrame: 3200, sequence: 2)
        _ = try await store.commitReceivedChunk(fixture.deliver(third, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: third.manifest.frames.end)
        let later = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(later.expectedGeneration == revised.generation)
        #expect(later.checkpoint?.sourceFrame == second.manifest.frames.end)
        #expect(later.inputs.map { $0.envelope.manifest.chunkID } == [third.manifest.chunkID])
        try await commitAnalysis(later, for: third)
        let laterRecognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let completed = try await store.commitWindowTranscript(ticket: laterRecognition, text: "最后确认发布。", rawResult: Data("{}".utf8))
        #expect(completed.spans.map(\.text) == [edited.text, "接着讨论设计。", "最后确认发布。"])
        #expect(completed.spans.first == edited)
        #expect(completed.generation == revised.generation)
        #expect(try await store.contextStatus().pendingAnalysisCount == 0)
        #expect(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        try await store.validateSources([revised.source(for: edited)])
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([original.source(for: firstSpan)]) }
        let reopened = try fixture.store()
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans == completed.spans)
    }
}

struct Fixture {
    static func audioData() -> Data { makeWAVFixture() }
    let root: URL
    let sessionID = UUID()
    let deviceID = UUID()
    let epochID = UUID()
    let audio = makeWAVFixture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("momo-archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
    func store() throws -> ArchiveStore { try ArchiveStore(rootURL: root.appendingPathComponent("Library"), receiverDeviceID: deviceID) }
    func envelope(chunkID: UUID = UUID(), audio data: Data? = nil, startFrame: Int64 = 0, frameCount: Int64 = 1600, sequence: Int64 = 0, sealedAt: Date = Date()) throws -> ManifestEnvelope {
        let data = data ?? (frameCount == 1600 ? audio : makeWAVFixture(frameCount: Int(frameCount)))
        return try ManifestEnvelope(manifest: ChunkManifest(sessionID: sessionID, epochID: epochID, chunkID: chunkID, sourceDeviceID: deviceID, sourceBuild: "tests", sequence: sequence, frames: FrameRange(start: startFrame, count: frameCount), timebaseHz: 16000, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: frameCount, byteCount: Int64(data.count), audioSHA256: ContentHash.sha256(data), sealedAt: sealedAt, sourceKind: .fixture))
    }
    func deliver(_ envelope: ManifestEnvelope, to store: ArchiveStore, audio data: Data? = nil) throws -> InboxItem {
        let file = root.appendingPathComponent(UUID().uuidString)
        let bytes = data ?? (envelope.manifest.decodedFrameCount == 1600 ? audio : makeWAVFixture(frameCount: Int(envelope.manifest.decodedFrameCount)))
        try bytes.write(to: file)
        return try store.inbox.preserve(fileURL: file, envelope: envelope)
    }
    func spans(_ ticket: AnalysisTicket) -> [TranscriptSpan] { [TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "整理下周安排，周一确认设计评审时间。")] }
    func transcribe(_ store: ArchiveStore) async throws -> TranscriptDocument {
        _ = try await store.commitReceivedChunk(deliver(envelope(), to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        return try await store.commitTranscript(ticket: ticket, spans: spans(ticket))
    }
}

private func makeWAVFixture(frameCount: Int = 1600) -> Data {
    let byteCount = frameCount * 2
    var data = Data("RIFF".utf8)
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    u32(UInt32(byteCount + 36)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(16000); u32(32000); u16(2); u16(16)
    data.append(Data("data".utf8)); u32(UInt32(byteCount)); data.append(Data(repeating: 0, count: byteCount))
    return data
}
