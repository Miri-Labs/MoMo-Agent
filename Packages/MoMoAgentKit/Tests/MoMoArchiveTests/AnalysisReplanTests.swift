import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

/// A speaker requeue after an analysis upgrade must re-plan audio, never reset carried windows:
/// a carried window's ID cannot be rebuilt by the planner, so its transcription always fails.
struct AnalysisReplanTests {
    let old = ContentHash.sha256(Data("old-detector".utf8))
    let new = ContentHash.sha256(Data("new-detector".utf8))

    @Test func speakerRequeueReplansAudioInsteadOfResettingCarriedWindows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let carried = try await upgradedHistory(store, fixture: fixture, envelope: envelope)
        try await store.upgradeSpeakerProfilesIfNeeded()
        // Until the configuration is known nothing is reset, so the carried copy is never claimable.
        #expect(try await windowStates(store, configuration: new) == [carried: "complete"])
        for previous in [old] { try await store.preserveCompletedAnalysis(from: previous, to: new) }
        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 1)
        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 0)

        #expect(try await windowStates(store, configuration: new).isEmpty)
        #expect(try await windowStates(store, configuration: old).values.allSatisfy { $0 == "complete" })
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans.isEmpty)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: new) == nil)
        try await drain(store, envelope: envelope)
        #expect(try await windowStates(store, configuration: new).values.allSatisfy { $0 == "complete" })
        #expect(try await windowStates(store, configuration: new)[carried] == nil)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans.map(\.text) == ["重新转写"])
    }

    @Test func repairReplansArchiveBrokenByInPlaceReset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let carried = try await upgradedHistory(store, fixture: fixture, envelope: envelope)
        // What the earlier requeue did: every complete window of every configuration back to pending.
        try await store.database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL,raw_result=NULL WHERE state='complete'")
        #expect(try await windowStates(store, configuration: new) == [carried: "pending"])

        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 1)
        #expect(try await windowStates(store, configuration: new).isEmpty)
        // The older configuration had no completed result left, so its dead work is dropped.
        #expect(try await windowStates(store, configuration: old).isEmpty)
        try await drain(store, envelope: envelope)
        #expect(try await windowStates(store, configuration: new).values.allSatisfy { $0 == "complete" })

        // Idempotent: the marker stops a second repair from re-planning finished work.
        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 0)
        #expect(try await windowStates(store, configuration: new).values.allSatisfy { $0 == "complete" })
        #expect(try await store.claimAutomaticWork(configurationFingerprint: new) == nil)
    }

    @Test func replanWaitsForAnActiveAnalysisAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await upgradedHistory(store, fixture: fixture, envelope: envelope)
        let next = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(next, to: store))
        let active = try #require(await store.claimEpochAnalysis(configurationFingerprint: new))
        try await store.requestAnalysisReplan(sessionID: fixture.sessionID)
        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 0)
        try await store.cancelEpochAnalysis(ticket: active)
        #expect(try await store.replanRequestedAnalysis(configurationFingerprint: new) == 1)
    }

    /// Old-configuration history with text, carried into the new configuration.
    private func upgradedHistory(_ store: ArchiveStore, fixture: Fixture, envelope: ManifestEnvelope) async throws -> String {
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        let window = try makeWindow(envelope, start: 0, count: 800, configuration: old)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [FrameRange(start: 800, count: 800)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: 1600, configurationFingerprint: old), waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: old))
        _ = try await store.commitWindowTranscript(ticket: recognition, text: "旧版转写", rawResult: Data("{}".utf8))
        try await store.preserveCompletedAnalysis(from: old, to: new)
        return ContentHash.sha256(Data("carry/\(window.id)/\(new)".utf8))
    }

    /// Plans the epoch with the new configuration and transcribes every window it produces.
    private func drain(_ store: ArchiveStore, envelope: ManifestEnvelope) async throws {
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: new))
        #expect(ticket.checkpoint == nil)
        try await store.commitAnalysisBatch(ticket: ticket,
            windows: [makeWindow(envelope, start: 0, count: 800, configuration: new)],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [FrameRange(start: 800, count: 800)],
            checkpoint: ArchiveCheckpoint(sessionID: ticket.sessionID, epochID: ticket.epochID,
                sourceFrame: 1600, configurationFingerprint: new), waitingForMoreAudio: false)
        while let window = try await store.claimTranscriptionWindow(configurationFingerprint: new) {
            _ = try await store.commitWindowTranscript(ticket: window, text: "重新转写", rawResult: Data("{}".utf8))
        }
    }

    private func windowStates(_ store: ArchiveStore, configuration: String) async throws -> [String: String] {
        var states: [String: String] = [:]
        for row in try await store.database.rows("SELECT id,state FROM analysis_windows WHERE configuration_hash=?", [.text(configuration)]) {
            states[try row.requireString(0)] = try row.requireString(1)
        }
        return states
    }

    private func makeWindow(_ envelope: ManifestEnvelope, start: Int64, count: Int64,
                            configuration: String) throws -> ArchiveAnalysisWindow {
        let m = envelope.manifest, range = try FrameRange(start: start, count: count)
        return ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(m.chunkID)/\(configuration)/\(start)".utf8)),
            sessionID: m.sessionID, epochID: m.epochID, analysisAnchor: 0, coreFrames: range, contextFrames: range,
            modelCoreFrames: range, modelContextFrames: range,
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: range)], configurationFingerprint: configuration)
    }
}
