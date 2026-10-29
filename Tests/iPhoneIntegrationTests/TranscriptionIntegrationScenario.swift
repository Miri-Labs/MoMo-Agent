import AVFoundation
import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoSpeech

public struct TranscriptionIntegrationEvidence: Sendable {
    public let sessionID: UUID
    public let chunkCount: Int
    public let spanCount: Int
    public let sourceRangeCount: Int
    public let report: TranscriptionRunReport
}

public enum TranscriptionIntegrationFailure: Error {
    case invalidFixture, pausedWorkExecuted, pauseWasNotPreserved, processingFailed(String?)
    case transcriptMismatch(expected: String, actual: String), lifecycleInvariant(String)
}

/// Uses real audio containers, Archive, native VAD/ASR and the App coordinator. No model stub or prefilled transcript.
public enum TranscriptionIntegrationScenario {
    public static func run(rootURL: URL, modelDirectory: URL, audioChunks: [URL],
                           expectedFragments: [String]) async throws -> TranscriptionIntegrationEvidence {
        guard !audioChunks.isEmpty, expectedFragments.count == 1, !expectedFragments[0].isEmpty else {
            throw TranscriptionIntegrationFailure.invalidFixture
        }
        let receiverDeviceID = UUID()
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: receiverDeviceID)
        let bundle = try SpeechModelBundle.load(from: modelDirectory)
        try bundle.validate()
        let nativeDecodes = OSAllocatedUnfairLock(initialState: 0)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration()) { event in
            if case .nativeDecodeStarted = event { nativeDecodes.withLock { $0 += 1 } }
        }
        let received = try await ingest(audioChunks, archive: archive)
        let sessionID = received.sessionID
        let first = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        try await first.pauseByUser()
        await first.requestWork()
        await first.suspendForSystem()
        await first.resumeAfterSystemSuspension()
        let paused = await first.runUntilIdle()
        guard paused.snapshot.phase == .paused, try await archive.recordings().allSatisfy({ $0.transcriptVersion == 0 }) else {
            throw TranscriptionIntegrationFailure.pausedWorkExecuted
        }
        let restarted = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        guard await restarted.snapshot().userPaused else { throw TranscriptionIntegrationFailure.pauseWasNotPreserved }
        try await restarted.resumeByUser()
        let report = await restarted.runUntilIdle()
        guard report.snapshot.phase == .idle else { throw TranscriptionIntegrationFailure.processingFailed(report.snapshot.failureCode) }
        let document = try await archive.readTranscript(sessionID: sessionID)
        guard document.spans.count == 1, report.transcribedWindows == 1,
              nativeDecodes.withLock({ $0 }) == 1 else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("expected_one_span_and_one_asr_window")
        }
        let text = document.spans.map(\.text).joined(separator: "\n")
        let expected = normalizedFixtureText(expectedFragments[0])
        guard normalizedFixtureText(text) == expected else {
            throw TranscriptionIntegrationFailure.transcriptMismatch(expected: expected, actual: text)
        }
        // Production Runtime owns the settled refresh. Recognition itself must
        // finish durably even when document projection has not run yet.
        let reopened = try ArchiveStore(rootURL: rootURL, receiverDeviceID: receiverDeviceID)
        guard try await reopened.readTranscript(sessionID: sessionID).spans == document.spans else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("unprojected_transcript_not_durable")
        }
        try await reopened.projectPendingDocuments(includeUnchanged: false)
        _ = try await reopened.transcriptFileURL(sessionID: sessionID)
        return TranscriptionIntegrationEvidence(sessionID: sessionID, chunkCount: audioChunks.count, spanCount: document.spans.count,
                                                sourceRangeCount: document.spans.reduce(0) { $0 + $1.sourceRanges.count }, report: report)
    }

    public static func verifySilentRecording(rootURL: URL, modelDirectory: URL, audioURL: URL) async throws {
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: UUID())
        _ = try await ingest([audioURL], archive: archive)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory), configuration: SpeechConfiguration())
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let suspended = await coordinator.runUntilIdle()
        guard suspended.snapshot.phase == .systemSuspended else { throw TranscriptionIntegrationFailure.lifecycleInvariant("startup_gate") }
        await coordinator.resumeAfterSystemSuspension()
        let report = await coordinator.runUntilIdle()
        guard report.snapshot.phase == .idle, report.transcribedWindows == 0,
              try await archive.recordings().first?.transcriptionState == .noSpeech else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("silence_not_complete")
        }
    }

    public static func verifyDeleteDuringRecognition(rootURL: URL, modelDirectory: URL, audioChunks: [URL]) async throws {
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: UUID())
        let received = try await ingest(audioChunks, archive: archive)
        let events = AsyncStream<SpeechExecutionEvent>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let steps = OSAllocatedUnfairLock(initialState: [NativeDeletionStep]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory), configuration: SpeechConfiguration()) { event in
            switch event {
            case .analysisPageReady: break
            case .nativeDecodeStarted(let windowID):
                steps.withLock { $0.append(.started(windowID)) }
                events.continuation.yield(event)
                let result = gate.wait(timeout: .now() + 30)
                steps.withLock { $0.append(result == .success ? .gateReleased : .gateTimedOut) }
            case .nativeDecodeReturned(let windowID):
                steps.withLock { $0.append(.returned(windowID)) }
                events.continuation.yield(event)
            }
        }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let deletion = Task {
            defer { gate.signal() }
            for await event in events.stream {
                guard case .nativeDecodeStarted = event else { continue }
                _ = try await archive.deleteSession(id: received.sessionID)
                steps.withLock { $0.append(.deletionCommitted) }
                guard received.audioURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("native_lease_deleted_early")
                }
                await coordinator.cancel(sessionID: received.sessionID)
                steps.withLock { $0.append(.cancellationCompleted) }
                return
            }
            throw TranscriptionIntegrationFailure.lifecycleInvariant("native_decode_not_reached")
        }
        let report = await coordinator.runUntilIdle()
        events.continuation.finish()
        try await deletion.value
        let observed = steps.withLock { $0 }
        guard !observed.contains(.gateTimedOut) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("native_gate_timed_out")
        }
        guard case .started(let windowID)? = observed.first,
              observed == [.started(windowID), .deletionCommitted, .cancellationCompleted,
                           .gateReleased, .returned(windowID)] else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("native_deletion_order: \(observed)")
        }
        guard report.snapshot.phase == .idle, report.transcribedWindows == 0,
              try await archive.recordings().isEmpty,
              received.audioURLs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("late_native_result_or_file_leak")
        }
    }

    #if DEBUG
    public static func verifyDeleteDuringClaim(rootURL: URL, modelDirectory: URL, audioChunks: [URL],
                                               duringRecognitionClaim: Bool, pauseAfterDeletion: Bool = false) async throws {
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: UUID())
        let deleted = try await ingest(audioChunks, archive: archive)
        let survivor = try await ingest(audioChunks, archive: archive)
        let nativeDecodes = OSAllocatedUnfairLock(initialState: 0)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory), configuration: SpeechConfiguration()) { event in
            if case .nativeDecodeStarted = event { nativeDecodes.withLock { $0 += 1 } }
        }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let claimed = AsyncStream<UUID>.makeStream()
        let gate = ClaimReturnGate()
        let expectedClaim: TranscriptionClaimKind = duringRecognitionClaim ? .transcription : .analysis
        await coordinator.observeClaims { kind, sessionID in
            guard kind == expectedClaim, sessionID == deleted.sessionID else { return }
            claimed.continuation.yield(sessionID)
            await gate.wait()
        }
        let deletion = Task {
            do {
                for await sessionID in claimed.stream {
                    // The Archive claim has acquired leases, but the coordinator has not adopted its ticket.
                    guard sessionID == deleted.sessionID, await coordinator.snapshot().activeSessionID == nil,
                          nativeDecodes.withLock({ $0 }) == 0 else {
                        throw TranscriptionIntegrationFailure.lifecycleInvariant("claim_gate_after_worker_handoff")
                    }
                    _ = try await archive.deleteSession(id: sessionID)
                    guard deleted.audioURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                        throw TranscriptionIntegrationFailure.lifecycleInvariant("claim_lease_deleted_early")
                    }
                    await coordinator.cancel(sessionID: sessionID)
                    if pauseAfterDeletion { try await coordinator.pauseByUser() }
                    // The analysis case needs no further wake. The ASR case also covers a receiver wake in this gap.
                    if duringRecognitionClaim { await coordinator.requestWork() }
                    await gate.open()
                    return
                }
                throw TranscriptionIntegrationFailure.lifecycleInvariant("claim_gate_not_reached")
            } catch {
                await gate.open()
                throw error
            }
        }
        var report = await coordinator.runUntilIdle()
        claimed.continuation.finish()
        try await deletion.value
        guard deleted.audioURLs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("cancelled_claim_leaked_audio_lease")
        }
        if pauseAfterDeletion {
            guard report.snapshot.phase == .paused, report.snapshot.userPaused, report.snapshot.failureCode == nil,
                  report.snapshot.activeSessionID == nil, nativeDecodes.withLock({ $0 }) == 0,
                  try await archive.recordings().allSatisfy({ $0.transcriptVersion == 0 }) else {
                throw TranscriptionIntegrationFailure.pauseWasNotPreserved
            }
            let restarted = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
            guard await restarted.snapshot().userPaused else { throw TranscriptionIntegrationFailure.pauseWasNotPreserved }
            try await coordinator.resumeByUser()
            report = await coordinator.runUntilIdle()
        }
        let remaining = try await archive.recordings()
        let document = try await archive.readTranscript(sessionID: survivor.sessionID)
        guard report.snapshot.phase == .idle, report.snapshot.failureCode == nil,
              report.snapshot.activeSessionID == nil, !report.snapshot.userPaused,
              remaining.map(\.sessionID) == [survivor.sessionID], document.spans.count == 1,
              nativeDecodes.withLock({ $0 }) == 1,
              try await archive.contextStatus().pendingAnalysisCount == 0 else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("delete_during_claim_stopped_other_recording")
        }
        let expected = normalizedFixtureText(PhoneTranscriptionFixture.expectedFragments[0])
        let actual = document.spans.map(\.text).joined(separator: "\n")
        guard normalizedFixtureText(actual) == expected else {
            throw TranscriptionIntegrationFailure.transcriptMismatch(expected: expected, actual: actual)
        }
        _ = try await archive.deleteSession(id: survivor.sessionID)
        guard survivor.audioURLs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("surviving_recording_leaked_audio_lease")
        }
    }
    #endif

    // Only whitespace and a boundary full stop may differ in this fixed Chinese fixture.
    private static func normalizedFixtureText(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "。."))
    }

    private enum NativeDeletionStep: Equatable, Sendable {
        case started(String), deletionCommitted, cancellationCompleted, gateReleased, gateTimedOut, returned(String)
    }

    public static func verifyFileRevisionDuringRecognition(rootURL: URL, modelDirectory: URL, audioChunks: [URL],
                                                          exhaustRetryBudget: Bool = false) async throws {
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: UUID())
        // Two real utterances separated by the fixture's silence produce two independent windows in one epoch.
        let received = try await ingest(audioChunks + audioChunks, archive: archive)
        let events = AsyncStream<String>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let revisionCount = exhaustRetryBudget ? 3 : 1
        let probe = OSAllocatedUnfairLock(initialState: (started: [String](), returned: [String](), timedOut: false))
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory), configuration: SpeechConfiguration()) { event in
            switch event {
            case .analysisPageReady: break
            case .nativeDecodeStarted(let windowID):
                let count = probe.withLock { $0.started.append(windowID); return $0.started.count }
                if (2...(revisionCount + 1)).contains(count) {
                    events.continuation.yield(windowID)
                    if gate.wait(timeout: .now() + 30) == .timedOut { probe.withLock { $0.timedOut = true } }
                }
            case .nativeDecodeReturned(let windowID): probe.withLock { $0.returned.append(windowID) }
            }
        }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let revision = Task {
            var appliedRevisions = 0
            for await _ in events.stream {
                defer { gate.signal() }
                let before = try await archive.readTranscript(sessionID: received.sessionID)
                guard before.spans.count == 1, let span = before.spans.first else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("revision_requires_first_committed_span")
                }
                let markdownURL = try await archive.transcriptFileURL(sessionID: received.sessionID)
                let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
                appliedRevisions += 1
                let revisedText = "人工修订第\(appliedRevisions)次：周二确认参观安排。"
                try Data(markdown.replacingOccurrences(of: span.text, with: revisedText).utf8).write(to: markdownURL, options: .atomic)
                let changes = try await archive.reconcileDocumentFiles()
                guard changes.count == 1, let change = changes.first, change.didRevise,
                      try change.result.get() == before.version + 1 else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("file_revision_not_reported")
                }
                // Same wake-up contract as PhoneRuntime.refresh; no new audio is delivered after this edit.
                await coordinator.requestWork()
                let document = try await archive.readTranscript(sessionID: received.sessionID)
                guard let edited = document.spans.first, edited.id == span.id, edited.text == revisedText else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("file_revision_not_committed")
                }
                if appliedRevisions == revisionCount { return edited }
            }
            throw TranscriptionIntegrationFailure.lifecycleInvariant("second_native_decode_not_reached")
        }
        var report = await coordinator.runUntilIdle()
        events.continuation.finish()
        let edited = try await revision.value
        var committedWindows = report.transcribedWindows
        if exhaustRetryBudget {
            let pendingDocument = try await archive.readTranscript(sessionID: received.sessionID)
            guard report.snapshot.phase == .failed, report.snapshot.failureCode == "transcript_repeatedly_revised",
                  report.transcribedWindows == 1, pendingDocument.spans == [edited],
                  probe.withLock({ $0.started.count }) == revisionCount + 1,
                  try await archive.contextStatus().pendingAnalysisCount > 0 else {
                throw TranscriptionIntegrationFailure.lifecycleInvariant("revision_retry_budget_lost_pending_work")
            }
            // The user can continue retained work once the external editor stops changing this file.
            try await coordinator.resumeByUser()
            report = await coordinator.runUntilIdle()
            committedWindows += report.transcribedWindows
        }
        let observed = probe.withLock { $0 }
        let document = try await archive.readTranscript(sessionID: received.sessionID)
        guard !observed.timedOut, observed.started.count == revisionCount + 2, observed.returned == observed.started,
              Set(observed.started.dropFirst()).count == 1, report.snapshot.phase == .idle, report.snapshot.failureCode == nil,
              committedWindows == 2, document.spans.count == 2,
              document.spans.first == edited, document.generation == Int64(revisionCount),
              try await archive.contextStatus().pendingAnalysisCount == 0 else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("revision_did_not_resume_without_new_audio")
        }
        let unchanged = try await archive.reconcileDocumentFiles()
        guard unchanged.allSatisfy({ !$0.didRevise }) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("unchanged_file_repeatedly_requests_work")
        }
    }

    public static func verifySavedContextLifecycle(rootURL: URL, sessionID: UUID, stagingURL: URL) async throws {
        let archive = try ArchiveStore(rootURL: rootURL, receiverDeviceID: UUID())
        let hits = try await archive.searchTranscripts(query: "开放时间")
        guard let source = hits.first?.source, source.sessionID == sessionID else { throw TranscriptionIntegrationFailure.lifecycleInvariant("search") }
        let parts = try await archive.acquireAudioTimeline(source: source)
        guard parts.count == 2 else { throw TranscriptionIntegrationFailure.lifecycleInvariant("cross_chunk_playback") }
        for part in parts where !FileManager.default.fileExists(atPath: part.lease.audioURL.path) {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("playback_file")
        }
        let first = parts[0]
        let rawManifest = try Data(contentsOf: first.lease.audioURL.appendingPathExtension("manifest.json"))
        let replay = try ManifestEnvelope(manifestData: rawManifest, manifestSHA256: ContentHash.sha256(rawManifest))
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let lateFile = stagingURL.appendingPathComponent("late-transfer.wav")
        try FileManager.default.copyItem(at: first.lease.audioURL, to: lateFile)
        for part in parts { await archive.releaseAudioLease(id: part.lease.id) }
        let agentSession = UUID()
        try await archive.registerAgentSources(agentSessionID: agentSession, sources: [source])
        let operation = UUID()
        let plan = try await archive.savePlan(operationID: operation, title: "参观安排", body: "根据录音中公布的开放时间安排参观。", sources: [source])
        let retry = try await archive.savePlan(operationID: operation, title: "参观安排", body: "根据录音中公布的开放时间安排参观。", sources: [source])
        guard plan.id == retry.id else { throw TranscriptionIntegrationFailure.lifecycleInvariant("plan_idempotency") }
        _ = try await archive.deleteSession(id: sessionID)
        guard try await archive.searchTranscripts(query: "开放时间").isEmpty,
              try await archive.plans().isEmpty,
              try await !archive.agentCanResume(agentSessionID: agentSession) else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("deletion_visibility")
        }
        let item = try archive.inbox.preserve(fileURL: lateFile, envelope: replay)
        guard case .deleted = try await archive.commitReceivedChunk(item) else { throw TranscriptionIntegrationFailure.lifecycleInvariant("late_file_resurrection") }
        guard try await archive.pendingReceipts().isEmpty else { throw TranscriptionIntegrationFailure.lifecycleInvariant("deleted_receipt") }
    }

    struct IngestedAudio: Sendable {
        let sessionID: UUID
        let audioURLs: [URL]
    }

    static func ingest(_ audioChunks: [URL], archive: ArchiveStore,
                       wallClockAnchor: Date = Date(timeIntervalSince1970: 1_790_000_000),
                       closeEpoch: Bool = true, sealedAt: Date = Date()) async throws -> IngestedAudio {
        guard !audioChunks.isEmpty else { throw TranscriptionIntegrationFailure.invalidFixture }
        let session = UUID(), epoch = UUID(), source = UUID()
        var position: Int64 = 0, rate: Double?
        var urls: [URL] = []
        for (index, file) in audioChunks.enumerated() {
            let manifest = try fixtureManifest(file: file, session: session, epoch: epoch, source: source,
                                               sequence: Int64(index), position: position, wallClockAnchor: wallClockAnchor, sealedAt: sealedAt)
            if let rate, rate != manifest.sampleRate { throw TranscriptionIntegrationFailure.invalidFixture }
            rate = manifest.sampleRate
            let temporary = archive.rootURL.appendingPathComponent("fixture-upload-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: temporary)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: temporary, envelope: ManifestEnvelope(manifest: manifest)))
            let lease = try await archive.acquireAudioLease(chunkID: manifest.chunkID)
            urls.append(lease.audioURL)
            await archive.releaseAudioLease(id: lease.id)
            position = manifest.frames.end
        }
        if closeEpoch { try await archive.markEpochClosed(epochID: epoch, endFrame: position) }
        return IngestedAudio(sessionID: session, audioURLs: urls)
    }

    // Keep the file handle within a synchronous scope, before Archive or native inference awaits.
    private static func fixtureManifest(file: URL, session: UUID, epoch: UUID, source: UUID,
                                        sequence: Int64, position: Int64, wallClockAnchor: Date, sealedAt: Date) throws -> ChunkManifest {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.fileFormat.streamDescription.pointee
        let codec: MoMoContracts.AudioCodec
        if format.mFormatID == kAudioFormatMPEG4AAC { codec = .aac }
        else if format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 16 { codec = .pcmInt16 }
        else if format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0 { codec = .pcmFloat32 }
        else { throw TranscriptionIntegrationFailure.invalidFixture }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw TranscriptionIntegrationFailure.invalidFixture }
        return try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: source, sourceBuild: "iphone-integration-fixture",
            sequence: sequence, frames: FrameRange(start: position, count: audio.length), timebaseHz: audio.processingFormat.sampleRate,
            wallClockAnchor: wallClockAnchor, timezoneOffset: 28800,
            codec: codec, sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount),
            decodedFrameCount: audio.length, byteCount: Int64(size), audioSHA256: ContentHash.sha256(fileAt: file), sealedAt: sealedAt, sourceKind: .fixture)
    }
}

#if DEBUG
/// The claimant suspends cooperatively; deletion can finish even on a single executor thread.
private actor ClaimReturnGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
#endif
