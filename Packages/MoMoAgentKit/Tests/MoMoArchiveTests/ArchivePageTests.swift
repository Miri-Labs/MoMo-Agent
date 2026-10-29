import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchivePageTests {
    @Test func recordingPagesReachOlderSessionsAcrossInsertDeleteAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        var sessions: [UUID] = []
        // Equal timestamps exercise the stable ID tie-breaker, beyond the Agent's 50-item limit.
        for _ in 0..<51 { sessions.append(try await insertRecording(fixture, store: store)) }
        let first = try await store.recordingsPage(limit: 50)
        #expect(first.items.count == 50)
        let cursor = try #require(first.nextCursor)
        let remaining = try #require(Set(sessions).subtracting(first.items.map(\.id)).first)
        let direct = try await store.recordingSummary(sessionID: remaining)
        #expect(direct.id == remaining)
        #expect(direct.chunkCount == 1)
        #expect(direct.transcriptionState == .pending)
        try await store.setKeepAudio(sessionID: remaining, keep: true)
        #expect(try await store.recordingSummary(sessionID: remaining).keepAudio)
        let unknown = UUID()
        await #expect(throws: ArchiveError.missingRecording(unknown)) { try await store.recordingSummary(sessionID: unknown) }
        let newlyReceived = try await insertRecording(fixture, store: store)
        _ = try await store.deleteSession(id: first.items[0].id)
        await #expect(throws: ArchiveError.sessionDeleted(first.items[0].id)) {
            try await store.recordingSummary(sessionID: first.items[0].id)
        }
        let reopened = try fixture.store()
        let second = try await reopened.recordingsPage(limit: 50, cursor: cursor)
        #expect(second.items.map(\.id) == [remaining])
        #expect(second.nextCursor == nil)
        #expect(!second.items.contains { $0.id == newlyReceived })
        await #expect(throws: ArchiveError.invalidQuery) { try await reopened.recordingsPage(cursor: "invalid") }
        let other = try Fixture()
        defer { other.remove() }
        let otherStore = try other.store()
        await #expect(throws: ArchiveError.invalidQuery) { try await otherStore.recordingsPage(cursor: cursor) }
    }

    @Test func transcriptPagesHaveStableSpanOrderAndBoundFilters() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "paging-test"))
        let spans = try (0..<21).map { index in
            TranscriptSpan(chunkID: ticket.chunkID, frames: try FrameRange(start: Int64(index * 10), count: 10), text: "测试稿：下周安排\(index)")
        }
        _ = try await store.commitTranscript(ticket: ticket, spans: spans)
        let from = Date(timeIntervalSince1970: 1_790_000_000)
        let before = from.addingTimeInterval(1)
        let first = try await store.searchTranscriptsPage(query: "下周安排", limit: 20, from: from, before: before)
        #expect(first.items.count == 20)
        let cursor = try #require(first.nextCursor)
        let second = try await store.searchTranscriptsPage(query: "下周安排", limit: 20, cursor: cursor, from: from, before: before)
        #expect(second.items.count == 1)
        #expect(second.nextCursor == nil)
        #expect(Set((first.items + second.items).map { $0.source.spanID }) == Set(spans.map(\.id)))
        #expect(try await store.searchTranscriptsPage(query: "下周安排", before: from).items.isEmpty)
        await #expect(throws: ArchiveError.invalidQuery) { try await store.searchTranscriptsPage(query: "不同词", cursor: cursor, from: from, before: before) }
        await #expect(throws: ArchiveError.invalidQuery) { try await store.searchTranscriptsPage(query: "下周安排", cursor: cursor) }
        await #expect(throws: ArchiveError.invalidQuery) { try await store.recordingsPage(cursor: cursor, from: from, before: before) }
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(try await store.searchTranscriptsPage(query: "下周安排", cursor: cursor, from: from, before: before).items.isEmpty)
    }

    private func insertRecording(_ fixture: Fixture, store: ArchiveStore) async throws -> UUID {
        let session = UUID()
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: session, epochID: UUID(),
            sourceDeviceID: fixture.deviceID, sourceBuild: "pagination-tests", sequence: 0,
            frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 0,
            codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
            byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        return session
    }
}
