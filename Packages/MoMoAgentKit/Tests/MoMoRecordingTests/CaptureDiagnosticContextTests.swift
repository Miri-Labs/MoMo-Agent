import CSQLite
import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct CaptureDiagnosticContextTests {
    @Test func legacyDiagnosticWithoutContextRemainsReadableFromLedger() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        _ = try fixture.store()
        let id = UUID(), sessionID = fixture.envelope.manifest.sessionID
        let legacy = Data("""
        {"id":"\(id.uuidString)","timestamp":"2026-10-16T00:00:00Z","code":"routeChanged",
         "sessionID":"\(sessionID.uuidString)","observedFrames":32000,"inputSampleRate":48000,
         "lastSampleUptime":12.5}
        """.utf8)
        let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try database.execute("INSERT INTO capture_diagnostics(id,payload) VALUES(?,?)", [.text(id.uuidString), .blob(legacy)])
        let restored = try #require(await fixture.store().captureDiagnostics().first)
        #expect(restored.id == id && restored.sessionID == sessionID)
        #expect(restored.code == .routeChanged && restored.observedFrames == 32_000)
        #expect(restored.context == nil)
        let payload = try #require(JSONSerialization.jsonObject(with: WireJSON.encode(restored)) as? [String: Any])
        #expect(payload["context"] == nil)
    }

    @Test func fullContextRoundTripsThroughPersistentLedger() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let context = CaptureDiagnosticContext(runID: UUID(), sequence: 7, sourceBuild: "diagnostic-tests", uptime: 20,
            intent: .recording, activity: .interrupted, generation: 3, trigger: .audioSession,
            routeChangeReason: 2, shouldResume: false,
            tap: CaptureDiagnosticTapSnapshot(receivedFrames: 96_000, receivedBlocks: 94, droppedBlocks: 1, lastTapUptime: 19.5),
            encoderProgressObservedAtUptime: 19, finalizationDuration: 0.5, recoveryDuration: 1.25,
            safeError: CaptureDiagnosticSafeError(family: .audioSession, domain: .osStatus, code: -10879))
        let event = CaptureDiagnostic(code: .resumeFailed, sessionID: fixture.envelope.manifest.sessionID,
            epochID: fixture.envelope.manifest.epochID, observedFrames: 32_000, inputSampleRate: 48_000,
            lastSampleUptime: 19, context: context)
        let store = try fixture.store()
        try await store.recordDiagnostic(event)
        let reopened = try fixture.store()
        let restored = try #require(await reopened.captureDiagnostics().first)
        #expect(restored.context == context)
        #expect(restored.epochID == event.epochID)
        #expect(try WireJSON.encode(restored) == WireJSON.encode(event))
    }

    @Test func boundedTransitionsKeepLatestFailureAndOriginalAudio() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let runID = UUID(), epochID = fixture.envelope.manifest.epochID
        let count = RecordingStore.diagnosticLimit + 5
        for index in 0..<count {
            let context = CaptureDiagnosticContext(runID: runID, sequence: UInt64(index), sourceBuild: "diagnostic-tests",
                uptime: Double(index), intent: .recording, activity: .interrupted, generation: 2, trigger: .recovery)
            let event = CaptureDiagnostic(code: index == count - 1 ? .resumeFailed : .resumeRequested,
                sessionID: fixture.envelope.manifest.sessionID, epochID: epochID, context: context)
            try await store.recordDiagnostic(event)
        }
        let reopened = try fixture.store()
        let events = try await reopened.captureDiagnostics()
        #expect(events.count == 64)
        #expect(events.first?.code == .resumeFailed && events.first?.epochID == epochID)
        #expect(events.first?.context?.runID == runID && events.first?.context?.sequence == UInt64(count - 1))
        #expect(events.last?.context?.sequence == 5)
        #expect(try await reopened.pendingChunkCount() == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
    }

    @Test func safeErrorNeverSerializesDescriptionPathsOrUntrustedDomain() throws {
        let secret = "DO-NOT-SERIALIZE-PRIVATE-DETAIL"
        let info: [String: Any] = [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: "/private/\(secret).m4a",
                                  NSUnderlyingErrorKey: NSError(domain: secret, code: 99)]
        let unknown = CaptureDiagnosticSafeError(error: NSError(domain: secret, code: 17, userInfo: info), family: .unknown)
        let cocoa = CaptureDiagnosticSafeError(error: NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: info), family: .filesystem)
        let sqlite = CaptureDiagnosticSafeError(error: RecordingDatabaseError(code: SQLITE_FULL, message: secret), family: .database)
        let application = CaptureDiagnosticSafeError(error: RecordingError.invalidDirectory(secret), family: .filesystem)
        #expect(unknown.domain == .unknown && unknown.code == 17)
        #expect(cocoa.domain == .cocoa && cocoa.code == 513)
        #expect(sqlite.domain == .sqlite && sqlite.code == Int(SQLITE_FULL))
        #expect(application.domain == .application && application.code == nil)
        let bytes = try WireJSON.encode([unknown, cocoa, sqlite, application])
        let payload = String(decoding: bytes, as: UTF8.self)
        #expect(!payload.contains(secret) && !payload.contains("/private/") && !payload.contains("userInfo"))
        let objects = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(objects.allSatisfy { Set($0.keys).isSubset(of: ["family", "domain", "code"]) })
        #expect(try WireJSON.decode([CaptureDiagnosticSafeError].self, from: bytes) == [unknown, cocoa, sqlite, application])
    }
}
