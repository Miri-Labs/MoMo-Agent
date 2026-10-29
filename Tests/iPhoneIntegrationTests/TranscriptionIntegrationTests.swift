import AVFoundation
import Foundation
import os
import MoMoArchive
import MoMoRecording
import XCTest
import MoMoContracts
import MoMoSpeech

@MainActor
final class TranscriptionIntegrationTests: XCTestCase {
    func testCrossFileTranscriptionAndSavedContextLifecycle() async throws {
        let input = try resources()
        let root = try runDirectory()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
                                                                 directory: root.appendingPathComponent("capture"))
        let phone = root.appendingPathComponent("phone")
        let evidence = try await TranscriptionIntegrationScenario.run(rootURL: phone, modelDirectory: input.model,
            audioChunks: chunks, expectedFragments: PhoneTranscriptionFixture.expectedFragments)
        XCTAssertEqual(evidence.chunkCount, 2)
        XCTAssertEqual(evidence.sourceRangeCount, 2)
        XCTAssertEqual(evidence.spanCount, 1)
        XCTAssertEqual(evidence.report.transcribedWindows, 1)
        XCTAssertEqual(evidence.report.snapshot.phase, .idle)
        try await TranscriptionIntegrationScenario.verifySavedContextLifecycle(rootURL: phone,
            sessionID: evidence.sessionID, stagingURL: root.appendingPathComponent("late-transfer"))
    }

    func testSilentRecordingWaitsForForegroundAndCompletesWithoutASR() async throws {
        let input = try resources()
        let root = try runDirectory()
        let audio = try PhoneTranscriptionFixture.makeSilence(directory: root.appendingPathComponent("capture"))
        try await TranscriptionIntegrationScenario.verifySilentRecording(rootURL: root.appendingPathComponent("phone"),
            modelDirectory: input.model, audioURL: audio)
    }

    func testDeleteDuringNativeRecognitionRejectsLateResultAndReleasesAudio() async throws {
        let input = try resources()
        let root = try runDirectory()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
                                                                 directory: root.appendingPathComponent("capture"))
        try await TranscriptionIntegrationScenario.verifyDeleteDuringRecognition(rootURL: root.appendingPathComponent("phone"),
            modelDirectory: input.model, audioChunks: chunks)
    }

    func testFileRevisionDuringRecognitionContinuesWithoutNewAudio() async throws {
        let input = try resources()
        let root = try runDirectory()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
                                                                 directory: root.appendingPathComponent("capture"))
        try await TranscriptionIntegrationScenario.verifyFileRevisionDuringRecognition(rootURL: root.appendingPathComponent("phone"),
            modelDirectory: input.model, audioChunks: chunks)
    }

    #if DEBUG
    func testDeleteDuringAnalysisClaimContinuesOtherRecording() async throws {
        try await verifyDeleteDuringClaim(duringRecognitionClaim: false)
    }

    func testDeleteDuringRecognitionClaimContinuesOtherRecording() async throws {
        try await verifyDeleteDuringClaim(duringRecognitionClaim: true)
    }

    func testDeleteDuringClaimPreservesUserPauseUntilExplicitResume() async throws {
        try await verifyDeleteDuringClaim(duringRecognitionClaim: true, pauseAfterDeletion: true)
    }

    private func verifyDeleteDuringClaim(duringRecognitionClaim: Bool, pauseAfterDeletion: Bool = false) async throws {
        let input = try resources()
        let root = try runDirectory()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
                                                                 directory: root.appendingPathComponent("capture"))
        try await TranscriptionIntegrationScenario.verifyDeleteDuringClaim(rootURL: root.appendingPathComponent("phone"),
            modelDirectory: input.model, audioChunks: chunks, duringRecognitionClaim: duringRecognitionClaim,
            pauseAfterDeletion: pauseAfterDeletion)
    }
    #endif

    func testRepeatedFileRevisionsStopRetryingAndCanResume() async throws {
        let input = try resources()
        let root = try runDirectory()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
                                                                 directory: root.appendingPathComponent("capture"))
        try await TranscriptionIntegrationScenario.verifyFileRevisionDuringRecognition(rootURL: root.appendingPathComponent("phone"),
            modelDirectory: input.model, audioChunks: chunks, exhaustRetryBudget: true)
    }

    func testDamagedAudioClaimDoesNotBlockAnotherRecording() async throws { try await verifyFailureIsolation(.claim) }
    func testAnalysisReadFailureDoesNotBlockAnotherRecording() async throws { try await verifyFailureIsolation(.analysis) }
    func testBackgroundAutomaticProcessingContinuesPastDamagedAudio() async throws { try await verifyFailureIsolation(.analysis, background: true) }
    #if DEBUG
    func testRecognitionReadFailureDoesNotBlockAnotherRecording() async throws { try await verifyFailureIsolation(.recognition) }
    #endif

    private enum FailurePhase { case claim, analysis, recognition }

    private func verifyFailureIsolation(_ phase: FailurePhase, background: Bool = false) async throws {
        let input = try resources(), root = try runDirectory()
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let badID: UUID
        var original: URL?
        var repairBytes: Data?
        var repairEnvelope: ManifestEnvelope?
        if phase == .recognition {
            let files = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio, directory: root.appendingPathComponent("bad"))
            badID = try await TranscriptionIntegrationScenario.ingest(files, archive: archive).sessionID
        } else {
            var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("bad"), sessionID: UUID(),
                epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "failure-isolation", sourceKind: .fixture,
                targetFrames: 1_600, wallClockAnchor: Date(timeIntervalSince1970: 1_700_000_000), timezoneOffset: 0)
            let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: 1_600)).first)
            let bytes = try Data(contentsOf: chunk.audioURL)
            repairBytes = bytes
            badID = UUID()
            let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: badID, epochID: UUID(), sourceDeviceID: UUID(),
                sourceBuild: "failure-isolation", sequence: 0, frames: FrameRange(start: 0, count: 1_600), timebaseHz: 16_000,
                wallClockAnchor: Date(timeIntervalSince1970: 1_700_000_000), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000,
                channels: 1, decodedFrameCount: 1_600, byteCount: Int64(bytes.count), audioSHA256: ContentHash.sha256(bytes),
                sealedAt: Date(timeIntervalSince1970: 1_700_000_001), sourceKind: .fixture))
            repairEnvelope = envelope
            let file = root.appendingPathComponent("bad-input.wav"); try bytes.write(to: file)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
            let lease = try await archive.acquireAudioLease(chunkID: envelope.manifest.chunkID)
            original = lease.audioURL
            await archive.releaseAudioLease(id: lease.id)
            if phase == .claim {
                var changed = bytes; changed[changed.count / 2] ^= 1
                try changed.write(to: lease.audioURL)
            }
        }
        let goodFiles = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: input.audio,
            directory: root.appendingPathComponent("good"), wallClockAnchor: Date(timeIntervalSince1970: 1_790_100_000))
        let good = try await TranscriptionIntegrationScenario.ingest(goodFiles, archive: archive)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: input.model), configuration: SpeechConfiguration())
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: background)
        addTeardownBlock { await coordinator.suspendForSystem() }
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        if background {
            _ = try await coordinator.startBackgroundAutomatic { value in completions.withLock { $0.append(value) } }
        }
        let corruption = OSAllocatedUnfairLock(initialState: (mutated: false, error: Optional<String>.none))
        #if DEBUG
        if phase != .claim {
            await coordinator.observeClaims { kind, id in
                guard kind == (phase == .analysis ? .analysis : .transcription), id == badID else { return }
                guard corruption.withLock({ value in
                    guard !value.mutated else { return false }
                    value.mutated = true
                    return true
                }) else { return }
                do {
                    let summary = try await archive.recordingSummary(sessionID: badID)
                    let timeline = try await archive.playbackTimeline(sessionID: badID, expectedGeneration: summary.generation)
                    let part = try XCTUnwrap(timeline.parts.first)
                    let lease = try await archive.acquireAudioLease(chunkID: part.manifest.chunkID)
                    do {
                        var bytes = try Data(contentsOf: lease.audioURL)
                        bytes[bytes.count / 2] ^= 1
                        try bytes.write(to: lease.audioURL)
                    } catch { await archive.releaseAudioLease(id: lease.id); throw error }
                    await archive.releaseAudioLease(id: lease.id)
                } catch {
                    corruption.withLock { $0.error = String(describing: error) }
                }
            }
        }
        #endif
        let report = await coordinator.runUntilIdle()
        let automaticRecovery = phase == .analysis && !background
        if !automaticRecovery { await coordinator.suspendForSystem() }
        if phase != .claim {
            XCTAssertNil(corruption.withLock { $0.error })
            XCTAssertTrue(corruption.withLock { $0.mutated })
        }
        let expectedPhase: TranscriptionPhase = phase == .analysis ? .waitingForRetry : .audioUnavailable
        XCTAssertEqual(report.snapshot.phase, background ? .systemSuspended : expectedPhase)
        if background {
            XCTAssertEqual(completions.withLock { $0.count }, 1)
            XCTAssertEqual(completions.withLock { $0.first?.reason }, .completed)
            XCTAssertNil(completions.withLock { $0.first?.failureCode })
        }
        XCTAssertEqual(report.transcribedWindows, 1, "A damaged recording must not prevent the independent healthy one from finishing.")
        let document = try await archive.readTranscript(sessionID: good.sessionID)
        XCTAssertTrue(document.spans.contains { $0.text.contains("开放时间") })
        let coverage = try await archive.recordingCoverage(sessionID: badID, configurationFingerprint: engine.configurationFingerprint)
        XCTAssertFalse(coverage.epochs.flatMap(\.failures).isEmpty)
        if let original { XCTAssertTrue(FileManager.default.fileExists(atPath: original.path)) }
        let reopened = try ArchiveStore(rootURL: archive.rootURL, receiverDeviceID: UUID())
        let waiting = try await reopened.processingWaitState(configurationFingerprint: engine.configurationFingerprint)
        if phase == .analysis {
            if case .retryScheduled = waiting { }
            else { XCTFail("The retry deadline must survive reopening the archive.") }
        } else { XCTAssertEqual(waiting, .unavailableAudio) }
        if let original, let repairBytes, let repairEnvelope {
            try repairBytes.write(to: original)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: original, envelope: repairEnvelope))
            if automaticRecovery {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while true {
                    let current = try await archive.recordingCoverage(sessionID: badID, configurationFingerprint: engine.configurationFingerprint)
                    if current.processedDuration == current.receivedDuration { break }
                    guard ContinuousClock.now < deadline else { return XCTFail("The existing retry timer must recover without another receive event or manual request.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                let completed = await coordinator.snapshot()
                XCTAssertEqual(completed.phase, .idle)
                await coordinator.suspendForSystem()
            } else {
                let summary = try await archive.recordingSummary(sessionID: badID)
                try await archive.prepareTranscriptionRetry(sessionID: badID, expectedGeneration: summary.generation)
                let recovered = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
                let completed = await recovered.runUntilIdle()
                await recovered.suspendForSystem()
                XCTAssertEqual(completed.snapshot.phase, .idle)
            }
            let coverage = try await archive.recordingCoverage(sessionID: badID, configurationFingerprint: engine.configurationFingerprint)
            XCTAssertEqual(coverage.processedDuration, coverage.receivedDuration)
            XCTAssertTrue(coverage.epochs.flatMap(\.failures).isEmpty)
        }
    }

    func testSequentialWindowsAvoidReplayingConsumedPrefixAndReleaseInputs() async throws {
        try await verifySequentialWindows(deleteAtSecondClaim: false)
    }

    #if DEBUG
    func testDeleteAfterSecondWindowClaimReleasesRetainedSequence() async throws {
        try await verifySequentialWindows(deleteAtSecondClaim: true)
    }
    #endif

    private func verifySequentialWindows(deleteAtSecondClaim: Bool) async throws {
        let input = try resources(), root = try runDirectory()
        let file = try AVAudioFile(forReading: input.audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let pcm = try XCTUnwrap(buffer.floatChannelData?[0])
        let voice = (8_000..<78_000).map { Int16(max(-32_768, min(32_767, (pcm[$0] * 32_767).rounded()))) }
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("capture"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "sequence-host", sourceKind: .fixture,
            targetFrames: 320_000, wallClockAnchor: Date(), timezoneOffset: 0)
        let totalFrames = 60 * 16_000
        var chunks = try writer.append((0..<totalFrames).map { voice[$0 % voice.count] })
        if let tail = try writer.finish() { chunks.append(tail) }
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(chunks.map(\.audioURL), archive: archive)
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: input.model), configuration: SpeechConfiguration(),
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let deletion = OSAllocatedUnfairLock(initialState: (claims: 0, held: false, error: Optional<String>.none))
        #if DEBUG
        if deleteAtSecondClaim {
            await coordinator.observeClaims { kind, sessionID in
                guard kind == .transcription else { return }
                let count = deletion.withLock { $0.claims += 1; return $0.claims }
                guard count == 2 else { return }
                do {
                    _ = try await archive.deleteSession(id: sessionID)
                    deletion.withLock { $0.held = received.audioURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
                    await coordinator.cancel(sessionID: sessionID)
                } catch { deletion.withLock { $0.error = String(describing: error) } }
            }
        }
        #endif
        let report = await coordinator.runUntilIdle()
        XCTAssertEqual(report.snapshot.phase, .idle)
        XCTAssertNil(report.snapshot.failureCode)
        let decodes = observations.withLock { $0.filter { $0.operation == .transcribe && $0.outcome == .completed } }
        if deleteAtSecondClaim {
            let state = deletion.withLock { $0 }
            XCTAssertNil(state.error)
            XCTAssertTrue(state.held, "Retained sequence must protect originals at the next claim")
            XCTAssertEqual(decodes.count, 1, "The deleted second ticket must never reach native inference")
            let recordings = try await archive.recordings()
            XCTAssertTrue(recordings.isEmpty)
        } else {
            XCTAssertGreaterThanOrEqual(decodes.count, 3)
            XCTAssertLessThanOrEqual(decodes.reduce(0) { $0 + $1.convertedModelFrames }, Int64(totalFrames + 4_096))
            XCTAssertLessThan(decodes.reduce(0) { $0 + $1.discardedPrefixModelFrames }, 16_000)
            let document = try await archive.readTranscript(sessionID: received.sessionID)
            XCTAssertEqual(document.spans.count, decodes.count)
            _ = try await archive.deleteSession(id: received.sessionID)
        }
        XCTAssertTrue(received.audioURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private func resources() throws -> (model: URL, audio: URL) {
        let model = try XCTUnwrap(Bundle.main.url(forResource: "Speech", withExtension: nil),
                                 "Missing host Speech resources. Run Native/SpeechVendor/prepare-models.py before building.")
        let bundle = Bundle(for: TranscriptionIntegrationTests.self)
        let audio = try XCTUnwrap(bundle.url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures"),
                                 "Missing test WAV. Run Tests/Support/prepare-fixtures.py before building.")
        try SpeechModelBundle.load(from: model).validate()
        XCTAssertEqual(try ContentHash.sha256(fileAt: audio), PhoneTranscriptionFixture.officialWAVSHA256)
        return (model, audio)
    }

    private func runDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoIntegration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let location = XCTAttachment(string: "Isolated test evidence: \(root.path)")
        location.name = "integration-evidence-directory"
        location.lifetime = .keepAlways
        add(location)
        return root
    }
}
