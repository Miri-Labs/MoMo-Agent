import AVFAudio
import Foundation
import SQLite3
import XCTest
import MoMoContracts
import MoMoLink
import MoMoRecording
@testable import MoMoAgentWatch

#if DEBUG && targetEnvironment(simulator)
/// Admitted capture uses native simulator input. Capacity, event delivery and the diagnostic write fault are controlled;
/// these tests do not prove physical Watch route switching or an actual media-server reset.
@MainActor
final class WatchCaptureReliabilityTests: XCTestCase {
    func testInterruptionEndWithoutPlaybackHintResumesTheSameRecordingAndRetainsAudio() async throws {
        let fixture = try await makeFixture()
        let runtime = fixture.runtime
        try await runtime.start()
        try await waitForSamples(runtime, store: fixture.store)
        let session = try XCTUnwrap(runtime.sessionID)
        let firstEpoch = try XCTUnwrap(runtime.epochID)
        fixture.audioSession.microphoneGate.interruptionBegan()
        await runtime.handleAudioEvent(.interruptionBegan)
        XCTAssertEqual(runtime.captureState.intent, .recording)
        XCTAssertEqual(runtime.captureState.activity, .interrupted)
        XCTAssertNil(runtime.epochID)
        fixture.audioSession.microphoneGate.interruptionEnded(shouldResume: false)
        await runtime.handleAudioEvent(.interruptionEnded(shouldResume: false))
        try await waitForSamples(runtime, store: fixture.store)
        XCTAssertEqual(runtime.sessionID, session)
        XCTAssertNotEqual(runtime.epochID, firstEpoch)
        try await runtime.pause()
        let chunks = try await fixture.store.pendingChunks()
        XCTAssertTrue(chunks.contains { $0.envelope.manifest.epochID == firstEpoch })
        XCTAssertEqual(Set(chunks.map { $0.envelope.manifest.epochID }).count, 2)
        let paused = runtime.captureState
        await runtime.handleAudioEvent(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(runtime.captureState, paused)
        XCTAssertNil(runtime.epochID)
    }

    func testPreflightCapacityRefusalKeepsItsReasonAfterFinalizationAndRestart() async throws {
        continueAfterFailure = false
        let capacityReader = CaptureCapacityReader { _ in 1 }
        let fixture = try await makeFixture(capacityReader: capacityReader)
        let runtime = fixture.runtime
        var refusal: CaptureCapacitySnapshot?
        do {
            try await runtime.start()
            XCTFail("Insufficient capacity must reject capture before starting an epoch.")
        } catch CaptureCapacityError.insufficient(let snapshot) {
            refusal = snapshot
        }
        let snapshot = try XCTUnwrap(refusal)
        XCTAssertEqual(snapshot.availableBytes, 1)
        XCTAssertEqual(snapshot.stage, .starting)
        XCTAssertGreaterThan(snapshot.budget.requiredBytes, snapshot.availableBytes)
        let sessionID = try XCTUnwrap(runtime.sessionID)
        XCTAssertEqual(runtime.captureState.intent, .paused)
        XCTAssertEqual(runtime.captureState.activity, .failed)
        XCTAssertEqual(runtime.captureState.capturedFrames, 0)
        XCTAssertNil(runtime.epochID)
        XCTAssertFalse(runtime.isFinalizingCapture)
        XCTAssertFalse(fixture.audioSession.microphoneGate.allowsInput())
        let reason = try XCTUnwrap(runtime.diagnostic)
        XCTAssertEqual(reason.code, .lowSpace)
        XCTAssertEqual(reason.capacity, snapshot)
        let history = try await fixture.store.captureDiagnostics()
        XCTAssertEqual(history.first?.code, .finalized, "Successful cleanup must still be persisted.")
        XCTAssertTrue(history.contains { $0.id == reason.id && $0.code == .lowSpace })
        let intent = try await fixture.store.intent(sessionID: sessionID)
        XCTAssertEqual(intent, .paused)
        let chunks = try await fixture.store.pendingChunks()
        let events = try await fixture.store.pendingCaptureEvents()
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertTrue(events.isEmpty, "Preflight refusal must not create an epoch or capture event.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("Encoding").path))
        for name in ["CaptureWorking", "CaptureReady", "CaptureRepair"] {
            let entries = try FileManager.default.contentsOfDirectory(at: fixture.rootURL.appendingPathComponent(name),
                                                                      includingPropertiesForKeys: nil)
            XCTAssertTrue(entries.isEmpty, "No audio may be written after preflight refusal.")
        }

        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox", isDirectory: true))
        let transport = try WatchConnectivityTransport(
            preserveFile: { _, _ in throw ReliabilityTestError.unexpectedConnectivity },
            preserveControl: { try controls.preserve($0) }, event: { _ in })
        let restoredAudio = WatchAudioSession()
        defer { restoredAudio.close() }
        let restored = WatchRuntime(store: fixture.store,
            encoderDirectory: fixture.rootURL.appendingPathComponent("Encoding", isDirectory: true),
            sourceDeviceID: UUID(), sourceBuild: "watch-reliability-test", controls: controls, transport: transport,
            capacityReader: capacityReader, audioSession: restoredAudio)
        restored.configureSimulatorTestCapture()
        await restored.bootstrap()
        XCTAssertTrue(restored.ready, restored.failure ?? "Bootstrap failed.")
        XCTAssertNil(restored.sessionID)
        XCTAssertEqual(restored.captureState.intent, .stopped)
        XCTAssertEqual(restored.elapsedSeconds, 0)
        XCTAssertEqual(restored.diagnostic?.id, reason.id)
        XCTAssertEqual(restored.diagnostic?.code, .lowSpace)
        let restoredState = restored.captureState
        await restored.handleAudioEvent(.interruptionEnded(shouldResume: true))
        await restored.handleAudioEvent(.mediaServicesReset)
        XCTAssertEqual(restored.captureState, restoredState)
        XCTAssertNil(restored.epochID)
        XCTAssertFalse(restoredAudio.microphoneGate.allowsInput())
        XCTAssertEqual(restored.diagnostic?.id, reason.id)
        let finalHistory = try await fixture.store.captureDiagnostics()
        XCTAssertEqual(finalHistory.map(\.id), history.map(\.id), "Late system events must not attempt a restart.")
        attach("watch-capacity-reason-survives-finalization", fields: [
            "scope": "controlled_capacity_preflight_real_runtime_and_persistent_ledger_no_audio_input",
            "rootID": fixture.rootURL.lastPathComponent, "sessionID": sessionID.uuidString,
            "availableBytes": snapshot.availableBytes, "requiredBytes": snapshot.budget.requiredBytes,
            "visibleCode": reason.code.rawValue, "historyCodes": history.map { $0.code.rawValue },
            "retainedChunkCount": chunks.count, "captureEventCount": events.count,
            "restartPreservedReason": restored.diagnostic?.id == reason.id
        ])
    }

    func testRealTapCapacityRefusalKeepsLowSpaceAfterSuccessfulCleanup() async throws {
        continueAfterFailure = false
        let reads = CapacityAdmissionReads()
        let fixture = try await makeFixture(capacityReader: CaptureCapacityReader { _ in
            reads.next() == 1 ? Int64.max : 1
        })
        let runtime = fixture.runtime
        try await runtime.start()
        let sessionID = try XCTUnwrap(runtime.sessionID)
        let deadline = ContinuousClock.now + .seconds(15)
        while runtime.failure == nil || runtime.isFinalizingCapture || runtime.epochID != nil {
            guard ContinuousClock.now < deadline else { throw ReliabilityTestError.timedOut("native first-chunk capacity refusal") }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(reads.value, 2, "Preflight must pass; the real encoder's first chunk must be refused.")
        let reason = try XCTUnwrap(runtime.diagnostic)
        XCTAssertEqual(reason.code, .lowSpace)
        let snapshot = try XCTUnwrap(reason.capacity)
        XCTAssertEqual(snapshot.availableBytes, 1)
        XCTAssertEqual(snapshot.stage, .starting)
        let epochID = try XCTUnwrap(reason.epochID)
        let tap = try XCTUnwrap(reason.context?.tap)
        XCTAssertGreaterThan(tap.receivedFrames, 0, "This refusal must follow actual microphone input.")
        XCTAssertGreaterThan(tap.receivedBlocks, 0)
        XCTAssertEqual(runtime.captureState.intent, .paused)
        XCTAssertEqual(runtime.captureState.activity, .failed)
        XCTAssertEqual(runtime.captureState.capturedFrames, 0)
        XCTAssertFalse(fixture.audioSession.microphoneGate.allowsInput())
        XCTAssertTrue(runtime.failure?.contains(CaptureCapacityError.insufficient(snapshot).localizedDescription) == true,
                      "The original capacity refusal must still reach the user after successful cleanup.")
        let history = try await fixture.store.captureDiagnostics()
        let completion = try XCTUnwrap(history.first)
        XCTAssertEqual(completion.code, .finalized)
        XCTAssertEqual(completion.epochID, epochID)
        XCTAssertNil(completion.context?.safeError)
        XCTAssertFalse(history.contains { $0.code == .cleanupFailed })
        XCTAssertTrue(history.contains { $0.id == reason.id })
        let chunks = try await fixture.store.pendingChunks()
        XCTAssertTrue(chunks.isEmpty)
        let epochDirectory = fixture.rootURL.appendingPathComponent("Encoding")
            .appendingPathComponent(sessionID.uuidString).appendingPathComponent(epochID.uuidString)
        let entries = try FileManager.default.contentsOfDirectory(at: epochDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.isEmpty, "Capacity refusal must happen before creating the AAC file.")
        let intent = try await fixture.store.intent(sessionID: sessionID)
        XCTAssertEqual(intent, .paused)
        let events = try await fixture.store.pendingCaptureEvents()
        let interruptions = events.compactMap { message -> CaptureEpochInterrupted? in
            if case .epochInterrupted(let event) = message { return event }
            return nil
        }
        XCTAssertEqual(interruptions.count, 1)
        XCTAssertEqual(interruptions.first?.epochID, epochID)
        XCTAssertEqual(interruptions.first?.reason, .failed)
        let stoppedState = runtime.captureState
        await runtime.handleAudioEvent(.interruptionEnded(shouldResume: true))
        await runtime.handleAudioEvent(.mediaServicesReset)
        XCTAssertEqual(runtime.captureState, stoppedState)
        XCTAssertNil(runtime.epochID)
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(runtime.diagnostic?.id, reason.id)
        let finalHistory = try await fixture.store.captureDiagnostics()
        XCTAssertEqual(finalHistory.map(\.id), history.map(\.id))
        attach("watch-native-capacity-refusal-keeps-reason", fields: [
            "scope": "real_simulator_tap_controlled_capacity_refusal_before_first_AAC_no_WC",
            "rootID": fixture.rootURL.lastPathComponent, "sessionID": sessionID.uuidString,
            "epochID": epochID.uuidString, "capacityReadCount": reads.value,
            "receivedTapFrames": tap.receivedFrames, "receivedTapBlocks": tap.receivedBlocks,
            "visibleCode": reason.code.rawValue, "completionCode": completion.code.rawValue,
            "retainedChunkCount": chunks.count, "epochInterruptionCount": interruptions.count
        ])
    }

    func testRealTapRejectsDisallowedInputBeforeDeliveringAnyPCM() async throws {
        continueAfterFailure = false
        let session = WatchAudioSession()
        let engine = AudioCaptureEngine()
        addTeardownBlock { @MainActor in
            engine.stop()
            defer { session.close() }
            try await session.deactivate()
        }
        try await session.activate()
        let selected = AVAudioSession.sharedInstance()
        XCTAssertEqual(selected.category, .record)
        XCTAssertEqual(selected.categoryOptions.rawValue, 0)
        XCTAssertFalse(selected.currentRoute.inputs.isEmpty)
        XCTAssertTrue(selected.currentRoute.inputs.allSatisfy { $0.portType == .builtInMic })

        let input = try engine.start(inputAllowed: { false })
        let rejection = try await withThrowingTaskGroup(of: RejectedInput.self) { group in
            group.addTask {
                var delivered = 0
                var iterator = input.blocks.makeAsyncIterator()
                do {
                    while try await iterator.next() != nil { delivered += 1 }
                } catch let error as AudioCaptureError {
                    return RejectedInput(deliveredBlocks: delivered, error: error)
                }
                throw ReliabilityTestError.inputEndedWithoutRejection
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw ReliabilityTestError.timedOut("first real microphone tap")
            }
            defer { group.cancelAll() }
            let first = try await group.next()
            return try XCTUnwrap(first)
        }
        engine.stop()
        XCTAssertEqual(rejection.error, .unexpectedInputRoute)
        XCTAssertEqual(rejection.deliveredBlocks, 0)
        let health = engine.healthSnapshot
        XCTAssertGreaterThan(health.receivedBlocks, 0)
        XCTAssertGreaterThan(health.receivedFrames, 0)
        XCTAssertNotNil(health.lastTapUptime)
        XCTAssertEqual(health.droppedBlocks, 0)
        attach("watch-route-gate-real-tap", fields: [
            "scope": "real_simulator_tap_with_controlled_closed_gate_no_physical_route_switch",
            "inputRate": input.sampleRate, "deliveredBlocks": rejection.deliveredBlocks,
            "receivedTapBlocks": health.receivedBlocks, "receivedTapFrames": health.receivedFrames,
            "routeType": "builtInMic", "categoryOptions": selected.categoryOptions.rawValue
        ])
    }

    func testMediaResetStartsANewRealEpochAndLateEventsCannotUndoUserPause() async throws {
        continueAfterFailure = false
        let fixture = try await makeFixture()
        let runtime = fixture.runtime
        try await runtime.start()
        try await waitForSamples(runtime, store: fixture.store)
        let sessionID = try XCTUnwrap(runtime.sessionID)
        let firstEpoch = try XCTUnwrap(runtime.epochID)
        let firstFrames = runtime.captureState.capturedFrames

        await runtime.handleAudioEvent(.mediaServicesReset)
        XCTAssertEqual(runtime.sessionID, sessionID)
        XCTAssertEqual(runtime.captureState.intent, .recording, runtime.failure ?? "Recording intent was lost.")
        let secondEpoch = try XCTUnwrap(runtime.epochID, runtime.failure ?? "Reset recovery did not create an epoch.")
        XCTAssertNotEqual(secondEpoch, firstEpoch)
        try await waitForSamples(runtime, store: fixture.store)
        let diagnostics = try await fixture.store.captureDiagnostics()
        let reset = try XCTUnwrap(diagnostics.first { $0.code == .mediaServicesReset })
        XCTAssertEqual(reset.sessionID, sessionID)
        XCTAssertEqual(reset.epochID, firstEpoch, "The diagnosis must preserve the disrupted epoch identity.")
        XCTAssertGreaterThanOrEqual(reset.observedFrames, firstFrames)
        XCTAssertEqual(reset.context?.trigger, .audioSession)
        XCTAssertEqual(reset.context?.intent, .recording)
        XCTAssertTrue(diagnostics.contains { $0.code == .resumeSucceeded && $0.epochID == secondEpoch })
        let recordingIntent = try await fixture.store.intent(sessionID: sessionID)
        XCTAssertEqual(recordingIntent, .recording)

        try await runtime.pause()
        let pausedState = runtime.captureState
        let pausedDuration = runtime.elapsedSeconds
        XCTAssertEqual(pausedState.intent, .paused)
        XCTAssertNil(runtime.epochID)
        XCTAssertEqual(runtime.inputLevel, 0)
        let chunks = try await fixture.store.pendingChunks()
        XCTAssertEqual(Set(chunks.map { $0.envelope.manifest.epochID }), [firstEpoch, secondEpoch])
        let events = try await fixture.store.pendingCaptureEvents()
        let endings = epochEndings(events)
        XCTAssertEqual(endings.count, 2)
        XCTAssertTrue(endings.contains { $0.epochID == firstEpoch && $0.reason == .interrupted })
        XCTAssertTrue(endings.contains { $0.epochID == secondEpoch && $0.reason == .paused })
        try validateAudio(chunks, endings: endings)

        await runtime.handleAudioEvent(.interruptionEnded(shouldResume: true))
        await runtime.handleAudioEvent(.mediaServicesReset)
        let observationEnds = ContinuousClock.now + .milliseconds(500)
        repeat {
            XCTAssertEqual(runtime.captureState, pausedState)
            XCTAssertNil(runtime.epochID)
            XCTAssertEqual(runtime.inputLevel, 0)
            XCTAssertEqual(runtime.elapsedSeconds, pausedDuration)
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < observationEnds

        let reopened = try RecordingStore(rootURL: fixture.rootURL)
        let pausedIntent = try await reopened.intent(sessionID: sessionID)
        XCTAssertEqual(pausedIntent, .paused)
        let retained = try await reopened.pendingChunks()
        XCTAssertEqual(retained.map { $0.envelope.manifest.chunkID }, chunks.map { $0.envelope.manifest.chunkID })
        let retainedEvents = try await reopened.pendingCaptureEvents()
        XCTAssertEqual(retainedEvents, events)
        try validateAudio(retained, endings: endings)
        let cleanup = try await reopened.cleanupAcknowledgedChunks()
        XCTAssertTrue(cleanup.isEmpty, "No receipt exists; both epochs must retain their original audio.")
        attach("watch-media-reset-recovery", fields: [
            "scope": "real_simulator_sampling_controlled_runtime_media_reset_event_no_WC",
            "rootID": fixture.rootURL.lastPathComponent, "sessionID": sessionID.uuidString,
            "disruptedEpoch": firstEpoch.uuidString, "recoveredEpoch": secondEpoch.uuidString,
            "diagnosticEpoch": reset.epochID?.uuidString ?? "", "pausedFrames": pausedState.capturedFrames,
            "retainedChunkCount": retained.count, "lateEventsKeptPaused": true
        ])
    }

    func testDiagnosticInsertFailureStillStopsSealsAndPreservesOriginalAudio() async throws {
        continueAfterFailure = false
        let fixture = try await makeFixture()
        let runtime = fixture.runtime
        try await runtime.start()
        try await waitForSamples(runtime, store: fixture.store)
        let sessionID = try XCTUnwrap(runtime.sessionID)
        let epochID = try XCTUnwrap(runtime.epochID)
        let observedFrames = runtime.captureState.capturedFrames
        try execute("""
            CREATE TRIGGER reliability_reject_diagnostic BEFORE INSERT ON capture_diagnostics
            BEGIN SELECT RAISE(FAIL, 'reliability_diagnostic_write_fault'); END;
            """, root: fixture.rootURL)
        var stopError: (any Error)?
        do { try await runtime.stop() }
        catch { stopError = error }
        let reported = try XCTUnwrap(stopError, "A failed diagnostic write must remain visible to the caller.")
        let safe = CaptureDiagnosticSafeError(error: reported, family: .database)
        XCTAssertEqual(safe.domain, .sqlite)
        XCTAssertEqual(safe.code, Int(SQLITE_CONSTRAINT))
        XCTAssertTrue(String(describing: reported).contains("reliability_diagnostic_write_fault"))
        XCTAssertEqual(runtime.captureState.intent, .stopped)
        XCTAssertEqual(runtime.captureState.activity, .stopped)
        XCTAssertNil(runtime.epochID)
        XCTAssertFalse(runtime.isFinalizingCapture)
        XCTAssertEqual(runtime.inputLevel, 0)
        XCTAssertFalse(fixture.audioSession.microphoneGate.allowsInput())
        let stoppedIntent = try await fixture.store.intent(sessionID: sessionID)
        XCTAssertEqual(stoppedIntent, .stopped)
        let stoppedState = runtime.captureState
        let chunks = try await fixture.store.pendingChunks()
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(Set(chunks.map { $0.envelope.manifest.epochID }), [epochID])
        let events = try await fixture.store.pendingCaptureEvents()
        let endings = epochEndings(events)
        let ending = try XCTUnwrap(endings.first { $0.epochID == epochID })
        XCTAssertEqual(ending.reason, .stopped)
        XCTAssertGreaterThanOrEqual(ending.endFrame, observedFrames)
        try validateAudio(chunks, endings: endings)

        try execute("DROP TRIGGER reliability_reject_diagnostic", root: fixture.rootURL)
        let reopened = try RecordingStore(rootURL: fixture.rootURL)
        let recovery = try await reopened.recover()
        XCTAssertTrue(recovery.damaged.isEmpty && recovery.missing.isEmpty && recovery.unfinished.isEmpty)
        let reopenedIntent = try await reopened.intent(sessionID: sessionID)
        XCTAssertEqual(reopenedIntent, .stopped)
        let retained = try await reopened.pendingChunks()
        XCTAssertEqual(retained.map { $0.envelope.manifest.chunkID }, chunks.map { $0.envelope.manifest.chunkID })
        let retainedEvents = try await reopened.pendingCaptureEvents()
        XCTAssertEqual(retainedEvents, events)
        try validateAudio(retained, endings: endings)
        XCTAssertEqual(runtime.captureState, stoppedState)
        let diagnostics = try await reopened.captureDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.code == .firstSamples && $0.epochID == epochID })
        XCTAssertFalse(diagnostics.contains { $0.code == .stopped || $0.code == .finalized },
                       "The trigger must reject actual diagnostic writes, not manufacture successful evidence.")
        attach("watch-diagnostic-fault-stopped-safely", fields: [
            "scope": "real_simulator_sampling_with_SQLite_diagnostic_insert_fault_no_WC",
            "rootID": fixture.rootURL.lastPathComponent, "sessionID": sessionID.uuidString,
            "epochID": epochID.uuidString, "sealedFrames": ending.endFrame,
            "sqliteCode": safe.code ?? -1, "retainedChunkCount": retained.count,
            "chunks": retained.map { ["id": $0.envelope.manifest.chunkID.uuidString,
                "sha256": $0.envelope.manifest.audioSHA256] }
        ])
    }

    private func makeFixture(capacityReader: CaptureCapacityReader = .live) async throws -> ReliabilityFixture {
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        for component in ["MoMoAgentSimulatorTests", UUID().uuidString] {
            root.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: root.path) {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw ReliabilityTestError.invalidDirectory }
            } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        }
        let store = try RecordingStore(rootURL: root)
        let controls = try ControlInbox(directory: root.appendingPathComponent("ControlInbox", isDirectory: true))
        let transport = try WatchConnectivityTransport(
            preserveFile: { _, _ in throw ReliabilityTestError.unexpectedConnectivity },
            preserveControl: { try controls.preserve($0) }, event: { _ in })
        let audioSession = WatchAudioSession()
        let runtime = WatchRuntime(store: store, encoderDirectory: root.appendingPathComponent("Encoding", isDirectory: true),
            sourceDeviceID: UUID(), sourceBuild: "watch-reliability-test", controls: controls, transport: transport,
            capacityReader: capacityReader, audioSession: audioSession)
        runtime.configureSimulatorTestCapture()
        let fixture = ReliabilityFixture(runtime: runtime, store: store, audioSession: audioSession, rootURL: root)
        addTeardownBlock { @MainActor in
            var firstError: (any Error)?
            do { try self.execute("DROP TRIGGER IF EXISTS reliability_reject_diagnostic", root: fixture.rootURL) }
            catch { firstError = error }
            do { if runtime.sessionID != nil { try await runtime.stop() } }
            catch { if firstError == nil { firstError = error } }
            do { try await audioSession.deactivate() }
            catch { if firstError == nil { firstError = error } }
            audioSession.close()
            if let firstError { throw firstError }
        }
        await runtime.bootstrap()
        XCTAssertTrue(runtime.ready, runtime.failure ?? "Bootstrap failed.")
        XCTAssertNil(runtime.sessionID)
        return fixture
    }

    private func waitForSamples(_ runtime: WatchRuntime, store: RecordingStore) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if runtime.captureState.activity == .failed || runtime.captureState.activity == .interrupted {
                XCTFail(runtime.failure ?? "Native capture stopped before one second of samples.")
                throw ReliabilityTestError.captureStopped
            }
            let diagnostics = try await store.captureDiagnostics()
            if runtime.captureState.capturedFrames >= 16_000,
               diagnostics.contains(where: { $0.code == .firstSamples && $0.epochID == runtime.epochID }) {
                XCTAssertEqual(runtime.captureState.activity, .recording)
                XCTAssertNotNil(runtime.captureState.lastSampleUptime)
                return
            }
            guard ContinuousClock.now < deadline else { throw ReliabilityTestError.timedOut("one second of native samples") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func epochEndings(_ events: [ControlMessage]) -> [CaptureEpochEnded] {
        events.compactMap { if case .epochEnded(let event) = $0 { event } else { nil } }
    }

    private func validateAudio(_ chunks: [RecordedChunk], endings: [CaptureEpochEnded]) throws {
        XCTAssertFalse(chunks.isEmpty)
        for (epoch, group) in Dictionary(grouping: chunks, by: { $0.envelope.manifest.epochID }) {
            var through: Int64 = 0
            for chunk in group.sorted(by: { $0.envelope.manifest.frames.start < $1.envelope.manifest.frames.start }) {
                let manifest = chunk.envelope.manifest
                XCTAssertEqual(chunk.state, .ready)
                XCTAssertEqual(manifest.sourceKind, .fixture)
                XCTAssertEqual(manifest.codec, .aac)
                XCTAssertEqual(manifest.sampleRate, 16_000)
                XCTAssertEqual(manifest.frames.start, through)
                XCTAssertGreaterThan(manifest.frames.count, 0)
                XCTAssertEqual(try ContentHash.sha256(fileAt: chunk.audioURL), manifest.audioSHA256)
                let audio = try AVAudioFile(forReading: chunk.audioURL)
                XCTAssertEqual(audio.length, manifest.decodedFrameCount + manifest.primingFrames + manifest.paddingFrames)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096))
                while audio.framePosition < audio.length {
                    try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, audio.length - audio.framePosition)))
                    guard buffer.frameLength > 0 else { throw ReliabilityTestError.incompleteAudio }
                }
                through = manifest.frames.end
            }
            XCTAssertEqual(endings.first { $0.epochID == epoch }?.endFrame, through)
        }
    }

    private func execute(_ sql: String, root: URL) throws {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(root.appendingPathComponent("recording.sqlite").path, &connection,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw ReliabilityTestError.sqlite(status)
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ReliabilityTestError.sqlite(result) }
    }

    private func attach(_ name: String, fields: [String: Any]) {
        do {
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                                           uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        } catch { XCTFail("Could not encode capture evidence: \(error)") }
    }
}

private struct ReliabilityFixture {
    let runtime: WatchRuntime
    let store: RecordingStore
    let audioSession: WatchAudioSession
    let rootURL: URL
}
private struct RejectedInput: Sendable { let deliveredBlocks: Int; let error: AudioCaptureError }
private final class CapacityAdmissionReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
private enum ReliabilityTestError: Error {
    case timedOut(String), inputEndedWithoutRejection, captureStopped, invalidDirectory
    case unexpectedConnectivity, incompleteAudio, sqlite(Int32)
}
#endif
