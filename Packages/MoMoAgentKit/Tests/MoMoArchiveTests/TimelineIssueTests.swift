import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TimelineIssueTests {
    private let fingerprint = ContentHash.sha256(Data("timeline-issues".utf8))
    private let anchor = Date(timeIntervalSince1970: 1_790_000_000)
    private var day: TimelineDay { TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar) }

    @Test func exactGapAndFailuresPreserveSuccessfulTextAndRetryOnlyTheChosenFailure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        // Legacy claims require a completed contiguous prefix within each epoch. Independent
        // epochs let the same session retain two real terminal failures without bypassing that rule.
        let firstFailureEpoch = UUID(), secondFailureEpoch = UUID()
        let envelopes = try [fixture.envelope(), failureEpoch(fixture, id: firstFailureEpoch, at: anchor.addingTimeInterval(1)),
                            failureEpoch(fixture, id: secondFailureEpoch, at: anchor.addingTimeInterval(2))]
        for envelope in envelopes { _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) }
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3_200)
        for id in [firstFailureEpoch, secondFailureEpoch] { try await store.markEpochClosed(epochID: id, endFrame: 1_600) }
        let complete = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(complete.chunkID == envelopes[0].manifest.chunkID)
        let original = try await store.commitTranscript(ticket: complete, spans: fixture.spans(complete))
        let firstFailure = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(firstFailure.chunkID == envelopes[1].manifest.chunkID)
        try await store.failAnalysis(ticket: firstFailure, errorCode: "legacy_decode_failed", retryable: false)
        let secondFailure = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(secondFailure.chunkID == envelopes[2].manifest.chunkID)
        try await store.failAnalysis(ticket: secondFailure, errorCode: "/private/not-a-user-facing-reason", retryable: false)
        let windows = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.paragraphs.map(\.source.spanID) == original.spans.map(\.id))
        #expect(window.state == .failed)
        #expect(window.issues.map(\.source.frames) == [try FrameRange(start: 1_600, count: 1_600),
                                                     firstFailure.manifest.frames, secondFailure.manifest.frames])
        #expect(window.issues.map(\.kind) == [.waitingForSync, .transcriptionFailed, .transcriptionFailed])
        #expect(window.issues.map(\.source.epochID) == [fixture.epochID, firstFailureEpoch, secondFailureEpoch])
        #expect(window.issues[1].failureReason == .audioRead)
        #expect(window.issues[2].failureReason == .unspecified)
        #expect(abs(window.issues[0].start.timeIntervalSince(anchor.addingTimeInterval(0.1))) < 0.000_001)
        #expect(abs(window.issues[0].end.timeIntervalSince(anchor.addingTimeInterval(0.2))) < 0.000_001)
        #expect(!window.hasUnknownTail)
        let reopened = try fixture.store()
        #expect(try await reopened.timelineWindow(window.id, configurationFingerprint: fingerprint)?.issues == window.issues)
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.timelineRetrySources(TimelineRetryRequest(window: window, issueID: window.issues[0].id))
        }
        let chosen = window.issues[1]
        let sources = try await store.timelineRetrySources(TimelineRetryRequest(window: window, issueID: chosen.id))
        #expect(sources.count == 1 && sources[0].frames == firstFailure.manifest.frames)
        #expect(sources[0].epochID == firstFailureEpoch)
        #expect(try await store.timelineRetryIsComplete(sources: sources, configurationFingerprint: fingerprint) == false)
        try await store.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: sources[0].generation, sources: sources)
        let retry = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(retry.chunkID == firstFailure.chunkID)
        _ = try await store.commitTranscript(ticket: retry, spans: fixture.spans(retry))
        #expect(try await store.claimAnalysisJob(configurationHash: fingerprint) == nil)
        let document = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(document.spans.contains(original.spans[0]))
        let remaining = try #require(await store.timelineWindow(window.id, configurationFingerprint: fingerprint))
        #expect(remaining.issues.filter { $0.kind == .transcriptionFailed }.map(\.source.frames) == [secondFailure.manifest.frames])
        #expect(remaining.issues.filter { $0.kind == .transcriptionFailed }.map(\.source.epochID) == [secondFailureEpoch])
        #expect(remaining.state == .failed)
        #expect(try await store.timelineRetryIsComplete(sources: sources, configurationFingerprint: fingerprint))
        for envelope in envelopes {
            let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
            #expect(try ContentHash.sha256(fileAt: lease.audioURL) == envelope.manifest.audioSHA256)
            await store.releaseAudioLease(id: lease.id)
        }
        await #expect(throws: ArchiveError.staleSource) {
            try await store.timelineRetrySources(TimelineRetryRequest(window: window, issueID: chosen.id))
        }
    }

    @Test func modernPendingWindowsRemainSeparateAndRetryCannotExpandPastTheSelectedIssue() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let envelopes = try (0..<3).map { try fixture.envelope(startFrame: Int64($0) * 1_600, sequence: Int64($0)) }
        for envelope in envelopes { _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) }
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 4_800)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let windows = try envelopes.map { envelope in
            let manifest = envelope.manifest
            return try ArchiveAnalysisWindow(id: ContentHash.sha256(Data(manifest.chunkID.uuidString.utf8)),
                sessionID: fixture.sessionID, epochID: fixture.epochID, analysisAnchor: manifest.frames.start,
                coreFrames: manifest.frames, contextFrames: manifest.frames, modelCoreFrames: FrameRange(start: 0, count: manifest.frames.count),
                modelContextFrames: FrameRange(start: 0, count: manifest.frames.count),
                sources: [ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                    audioSHA256: manifest.audioSHA256, sourceFrames: manifest.frames)], configurationFingerprint: fingerprint)
        }
        try await store.commitAnalysisBatch(ticket: analysis, windows: windows,
            analyzedCoverage: [FrameRange(start: 0, count: 4_800)], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let original = try await store.commitWindowTranscript(ticket: first, text: "已有成功文字必须保留。", rawResult: Data())
        let window = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(window.issues.map(\.source.frames) == Array(envelopes.dropFirst()).map(\.manifest.frames))
        #expect(window.issues.allSatisfy { $0.kind == .waitingForTranscription })
        let selected = window.issues[1]
        await #expect(throws: ArchiveError.staleSource) {
            try await store.timelineRetrySources(TimelineRetryRequest(window: window, issueID: selected.id,
                frames: FrameRange(start: 1_600, count: 3_200)))
        }
        let scope = try await store.timelineRetrySources(TimelineRetryRequest(window: window, issueID: selected.id))
        try await store.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: scope[0].generation, sources: scope)
        let retry = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: scope[0].generation, sources: scope))
        #expect(retry.window.id == windows[2].id)
        let updated = try await store.commitWindowTranscript(ticket: retry, text: "仅补这一段。", rawResult: Data())
        #expect(updated.spans.contains(original.spans[0]))
        let remaining = try #require(await store.timelineWindow(window.id, configurationFingerprint: fingerprint))
        #expect(remaining.issues.map(\.source.frames) == [envelopes[1].manifest.frames])
        let stale = TimelineRetryRequest(window: remaining, issueID: remaining.issues[0].id)
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: updated.version, spans: updated.spans)
        await #expect(throws: ArchiveError.staleSource) { try await store.timelineRetrySources(stale) }
        let current = try #require(await store.timelineWindow(window.id, configurationFingerprint: fingerprint))
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.timelineRetrySources(TimelineRetryRequest(window: current, issueID: current.issues[0].id))
        }
    }

    @Test func unknownTailHasNoInventedGapAndMissingLocalAudioCannotBeRetried() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let open = try #require(await store.timelineDay(day).first)
        #expect(open.hasUnknownTail)
        #expect(!open.issues.contains { $0.kind == .waitingForSync })
        // Date arithmetic may differ by one floating-point ULP, well below one 16 kHz frame.
        #expect(abs(open.end.timeIntervalSince(anchor.addingTimeInterval(0.1))) < 0.000_001)
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        let missing = try #require(await store.timelineDay(day).first)
        #expect(missing.state == .failed)
        let issue = try #require(missing.issues.first { $0.kind == .audioUnavailable })
        #expect(!issue.canRetry)
        #expect(!missing.issues.contains { $0.canRetry })
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.timelineRetrySources(TimelineRetryRequest(window: missing, issueID: issue.id))
        }
    }

    private func failureEpoch(_ fixture: Fixture, id: UUID, at date: Date) throws -> ManifestEnvelope {
        try ManifestEnvelope(manifest: ChunkManifest(sessionID: fixture.sessionID, epochID: id,
            sourceDeviceID: fixture.deviceID, sourceBuild: "timeline-issues", sequence: 0,
            frames: FrameRange(start: 0, count: 1_600), timebaseHz: 16_000, wallClockAnchor: date,
            timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: 1_600, byteCount: Int64(fixture.audio.count),
            audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture))
    }
}
