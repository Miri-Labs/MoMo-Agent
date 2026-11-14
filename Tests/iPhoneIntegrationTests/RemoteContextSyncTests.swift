import Foundation
import XCTest
import MoMoAgentClient
import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

@MainActor
final class RemoteContextSyncTests: XCTestCase {
    func testCancelledUploadCleanupCannotClearReplacementTask() async throws {
        let (sync, root, archive, _) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        let first = expectation(description: "Old source request held")
        MemoryResponse.state.holdNextSource(first)
        let old = Task { try await sync.synchronize(includeMemories: false) }
        await fulfillment(of: [first], timeout: 5)
        sync.cancelSynchronization()
        MemoryResponse.state.releaseSource()
        let second = expectation(description: "Replacement source request held")
        MemoryResponse.state.holdNextSource(second)
        defer { MemoryResponse.state.releaseSource() }
        let replacement = Task { try await sync.synchronize(includeMemories: false) }
        await fulfillment(of: [second], timeout: 5)
        do { try await old.value; XCTFail("Old delivery must be cancelled") } catch { }
        XCTAssertTrue(sync.isUploadingSources)
        MemoryResponse.state.releaseSource()
        try await replacement.value
        XCTAssertFalse(sync.isUploadingSources)
        XCTAssertEqual(sync.pendingSources, 0)
    }

    func testCorruptNotebookCachePreservesSourceOutboxAndCanRecover() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        MemoryResponse.state.rejectSources = true
        do { try await sync.synchronize(includeMemories: false) } catch { }
        let cache = root.appendingPathComponent("memories-cache.json")
        let invalid = Data("incomplete".utf8)
        try invalid.write(to: cache)
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                            key: "fixture", configuration: configuration())
        XCTAssertEqual(restored.pendingSources, 1)
        XCTAssertNotNil(restored.failure)
        XCTAssertEqual(try Data(contentsOf: cache), invalid, "Opening a broken cache does not delete it")
        await restored.refreshMemories()
        XCTAssertNil(restored.failure)
        XCTAssertEqual(restored.memories.count, 1)
        XCTAssertEqual(restored.pendingSources, 1)
        restored.background()
    }

    func testSlowReviewMetadataDoesNotHoldNotebookRead() async throws {
        let (sync, _, _, _) = try fixture()
        let entered = expectation(description: "Review request held")
        MemoryResponse.state.holdNextStatus(entered)
        defer { MemoryResponse.state.releaseStatus(); sync.background() }
        let read = Task { await sync.refreshMemories() }
        await fulfillment(of: [entered], timeout: 5)
        await read.value
        XCTAssertNotNil(sync.lastSynced)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertEqual(sync.memories.count, 1)
    }

    func testOversizedSourceRemainsStoredWithoutAutomaticReplayAndCanBeRetried() async throws {
        let (sync, root, archive, _) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        MemoryResponse.state.sourceFailureStatus = 413
        try await sync.synchronize(includeMemories: false)
        XCTAssertEqual(sync.pendingSources, 1)
        XCTAssertFalse(sync.needsDelivery)
        XCTAssertNotNil(sync.sourceDeliveryFailure)
        let count = MemoryResponse.state.sourceAttempts
        try await sync.synchronize(includeMemories: false)
        XCTAssertEqual(MemoryResponse.state.sourceAttempts, count)
        MemoryResponse.state.sourceFailureStatus = nil
        try sync.allowSourceDeliveryRetry()
        try await sync.synchronize(includeMemories: false)
        XCTAssertEqual(sync.pendingSources, 0)
        XCTAssertFalse(sync.sources.isEmpty, "Acknowledgement must retain complete source references")
    }

    func testSourceRetryAfterDoesNotBlockNotesAndSurvivesForegroundRetry() async throws {
        let (sync, root, archive, _) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        MemoryResponse.state.sourceFailureStatus = 429
        do { try await sync.synchronize(includeMemories: false); XCTFail() } catch { }
        let count = MemoryResponse.state.sourceAttempts
        sync.background()
        try sync.allowSourceDeliveryRetry()
        do { try await sync.synchronize(includeMemories: false); XCTFail() } catch { }
        XCTAssertEqual(MemoryResponse.state.sourceAttempts, count)
        await sync.refreshMemories()
        XCTAssertNotNil(sync.lastSynced)
        sync.background()
    }

    func testMemoryRefreshFinishesDuringHeldUploadAndBothCachesSurviveRestart() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        let entered = expectation(description: "Source receipt held")
        MemoryResponse.state.holdNextSource(entered)
        defer { MemoryResponse.state.releaseSource() }
        let upload = Task { try await sync.synchronize(includeMemories: false) }
        await fulfillment(of: [entered], timeout: 5)
        await sync.refreshMemories()
        XCTAssertNotNil(sync.lastSynced)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertTrue(sync.isUploadingSources)
        let memoryFile = root.appendingPathComponent("memories-cache.json")
        let saved = try Data(contentsOf: memoryFile)
        MemoryResponse.state.releaseSource()
        try await upload.value
        XCTAssertEqual(try Data(contentsOf: memoryFile), saved, "A source receipt must not rewrite notebook cache")
        let reopened = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                            key: "fixture", configuration: configuration())
        XCTAssertEqual(reopened.memories, sync.memories)
        XCTAssertFalse(reopened.needsDelivery)
        XCTAssertNotNil(reopened.lastSourcesSent)
    }

    func testCancelledMemoryTaskCannotCaptureForegroundRefreshOrReviveDeletedNote() async throws {
        let (sync, _, _, _) = try fixture()
        await sync.refreshMemories()
        let note = try XCTUnwrap(sync.memories.first)
        let entered = expectation(description: "Old notebook response held")
        MemoryResponse.state.holdNextMemory(entered)
        defer { MemoryResponse.state.releaseMemory() }
        let old = Task { await sync.refreshMemories() }
        await fulfillment(of: [entered], timeout: 5)
        sync.background()
        MemoryResponse.state.allowForget = true
        await sync.forget(note)
        XCTAssertTrue(sync.memories.isEmpty)
        XCTAssertFalse(sync.isSyncing)
        MemoryResponse.state.releaseMemory()
        await old.value
        XCTAssertTrue(sync.memories.isEmpty, "An older response cannot restore a confirmed deletion")
    }

    func testReviewStatusFailureDoesNotPreventNotebookRead() async throws {
        let (sync, _, _, _) = try fixture()
        MemoryResponse.state.rejectStatus = true
        await sync.refreshMemories()
        XCTAssertNotNil(sync.lastSynced)
        XCTAssertNil(sync.failure)
        XCTAssertEqual(sync.memories.count, 1)
    }

    func testFiveHundredQueuedSourcesStopAfterFirstTransientFailureAndLeaveNotesAvailable() async throws {
        let (sync, root, archive, connection) = try fixture()
        await sync.refresh()
        let path = root.appendingPathComponent("context.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var queued: [String: Any] = [:]
        for _ in 0..<500 {
            let envelope = SourceEnvelope(library: archive.libraryInstanceID, session: UUID(), device: UUID(),
                generation: 0, version: 1, recordedAt: Date(), spans: [.init(id: UUID(), text: String(repeating: "完整录音正文", count: 100), recordedAt: Date())])
            queued[envelope.sessionId] = ["envelope": try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))]
        }
        state["sources"] = queued
        try JSONSerialization.data(withJSONObject: state).write(to: path)
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                            key: "fixture", configuration: configuration())
        MemoryResponse.state.rejectSources = true
        let entered = expectation(description: "First failing source is held")
        MemoryResponse.state.holdNextSource(entered)
        defer { MemoryResponse.state.releaseSource() }
        let upload = Task { try await restored.synchronize(includeMemories: false) }
        await fulfillment(of: [entered], timeout: 10)
        let started = ContinuousClock.now
        await restored.refreshMemories()
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertNil(restored.failure)
        MemoryResponse.state.releaseSource()
        do { try await upload.value; XCTFail("The source outage must remain visible") } catch { }
        XCTAssertEqual(MemoryResponse.state.sourceAttempts, 1)
        XCTAssertEqual(restored.pendingSources, 500)
        XCTAssertTrue(restored.needsDelivery)
    }

    func testStickerObservationSurvivesSourceReceiptAndRestartUntilExplicitlyDisabled() async throws {
        let (sync, root, archive, connection) = try fixture()
        try sync.markSourcesChanged()
        let firstRevision = sync.sourceChangeRevision
        try await sync.synchronize(includeMemories: false)
        XCTAssertFalse(sync.needsDelivery)
        XCTAssertTrue(sync.needsIllustrationRefresh, "Source acceptance happens before the Mac finishes generating")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertTrue(restored.needsIllustrationRefresh)
        XCTAssertTrue(restored.hasUnfinishedIllustrationDownload)
        try restored.didRefreshIllustrations(enabled: true, sourceRevision: firstRevision)
        XCTAssertTrue(restored.needsIllustrationRefresh, "An empty queue can still be in its conversation quiet period")
        XCTAssertFalse(restored.hasUnfinishedIllustrationDownload)
        try restored.markSourcesChanged()
        try restored.didRefreshIllustrations(enabled: false, sourceRevision: firstRevision)
        XCTAssertTrue(restored.needsIllustrationRefresh, "An old refresh cannot retire a newer change")
        try restored.didRefreshIllustrations(enabled: false, sourceRevision: restored.sourceChangeRevision)
        XCTAssertFalse(restored.needsIllustrationRefresh)
        let reopened = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertFalse(reopened.needsIllustrationRefresh)
    }

    func testChangeDuringUploadRemainsPendingAfterTheEarlierReceipt() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        try sync.markSourcesChanged()
        let received = expectation(description: "Mac received source, receipt still in flight")
        MemoryResponse.state.holdNextSource(received)
        defer { MemoryResponse.state.releaseSource() }
        let upload = Task { try await sync.synchronize(includeMemories: false) }
        await fulfillment(of: [received], timeout: 5)
        try sync.markSourcesChanged()
        MemoryResponse.state.releaseSource()
        try await upload.value
        XCTAssertTrue(sync.needsDelivery, "The earlier receipt cannot acknowledge a newer archive change")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertTrue(restored.needsDelivery)
        let acknowledged = MemoryResponse.state.syncedSourceIDs
        try await restored.synchronize(includeMemories: false)
        XCTAssertFalse(restored.needsDelivery)
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, acknowledged)
    }

    func testOfflineBackgroundOutboxSurvivesRestartAndAcknowledgedSourceIsNotReplayed() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        try sync.markSourcesChanged()
        MemoryResponse.state.rejectSources = true
        do {
            try await sync.synchronize(includeMemories: false)
            XCTFail("The offline source must remain pending")
        } catch { }
        XCTAssertTrue(sync.needsDelivery)
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertTrue(restored.needsDelivery)
        MemoryResponse.state.rejectSources = false
        try await restored.synchronize(includeMemories: false)
        XCTAssertFalse(restored.needsDelivery)
        XCTAssertTrue(restored.memories.isEmpty, "Background delivery does not refresh the memory UI")
        let acknowledged = MemoryResponse.state.syncedSourceIDs
        try await restored.synchronize(includeMemories: false)
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, acknowledged)
        let reopened = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertFalse(reopened.needsDelivery)
    }

    func testMemoryExcerptOnlyMovesRecognizedSourcePrefix() {
        let stamped = "10/29–30 录音 0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78 (归属/执行未核)：保留这段内容。"
        let preview = MemoryPreview(text: stamped)
        XCTAssertEqual(preview.date, "10/29–30")
        XCTAssertEqual(preview.text, "保留这段内容。")
        XCTAssertEqual(preview.sourceNote, "归属/执行未核")
        for text in ["11/3 提醒我复测 v2 模型。", "正文里引用 0fcdf941-b14c-4087-ad0e-a3eab9495fe2，不应删除。", "10/29 0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78", "10/29 录音 invalid-id v78 仍要显示。"] {
            XCTAssertEqual(MemoryPreview(text: text).text, text)
            XCTAssertNil(MemoryPreview(text: text).date)
        }
    }

    func testRecordingSummaryOutboxResumesAndCachesWithoutModelKey() async throws {
        let (sync, root, archive, connection) = try fixture()
        let window = try await summaryWindow(archive: archive, root: root)
        let first = try XCTUnwrap(sync.recordingSummaries)
        let pending = try await first.summaries(for: [window])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(MemoryResponse.state.requests, 0, "Offline queueing must not wait for the Mac")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        let summaries = try XCTUnwrap(restored.recordingSummaries)
        let received = expectation(description: "Mac summary applied after reopening")
        summaries.onChanged = { received.fulfill() }
        summaries.foreground()
        await fulfillment(of: [received], timeout: 8)
        summaries.background()
        XCTAssertEqual(MemoryResponse.state.requests, 2, "POST admits once; GET retrieves the completed result")
        let cache = try await summaries.summaries(for: [window])
        XCTAssertEqual(cache[window.summaryRevision], "团队决定周五交付。")
        let again = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        let cached = try await again.recordingSummaries?.summaries(for: [window])
        XCTAssertEqual(cached, cache)
        let requests = MemoryResponse.state.requests
        _ = try await archive.deleteSession(id: window.paragraphs[0].source.sessionID)
        let removed = try await again.recordingSummaries?.summaries(for: [window])
        XCTAssertTrue(removed?.isEmpty == true, "Deleted source must never revive its old summary")
        XCTAssertEqual(requests, MemoryResponse.state.requests)
    }

    private func summaryWindow(archive: ArchiveStore, root: URL) async throws -> TimelineWindow {
        let audio = Self.makeWAVFixture(), now = Date()
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), chunkID: UUID(),
            sourceDeviceID: UUID(), sourceBuild: "tests", sequence: 0, frames: FrameRange(start: 0, count: 1600),
            timebaseHz: 16000, wallClockAnchor: now, timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000,
            channels: 1, decodedFrameCount: 1600, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio),
            sealedAt: now, sourceKind: .fixture))
        let file = root.appendingPathComponent(UUID().uuidString)
        try audio.write(to: file)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "summary-test")
        let ticket = try XCTUnwrap(claimed)
        let span = TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames,
                                  text: "团队今天讨论了发布安排，明确决定下周五交付第一版，并由小林准备演示材料。")
        _ = try await archive.commitTranscript(ticket: ticket, spans: [span])
        let snapshot = try await archive.transcriptSnapshot(sessionID: ticket.manifest.sessionID)
        let found = try await archive.timelineWindow(containing: snapshot.document.source(for: span))
        return try XCTUnwrap(found)
    }
    func testOrdinaryChatDoesNotWaitForArchiveOrMemoryDownload() async throws {
        let (sync, _, _, _) = try fixture()
        try await sync.prepareSubmission(input: "你好，接着聊")
        XCTAssertEqual(MemoryResponse.state.requests, 0)
    }
    func testNativeMemoryCacheSurvivesRestartAndFailedDeleteIsNotQueued() async throws {
        let (sync, root, archive, connection) = try fixture()
        await sync.refresh()
        XCTAssertNil(sync.failure); XCTAssertEqual(sync.memories.first?.basis, "momo")
        let memory = try XCTUnwrap(sync.memories.first)
        await sync.forget(memory)
        XCTAssertNotNil(sync.failure); XCTAssertEqual(sync.memories.count, 1)
        XCTAssertFalse(sync.hasLegacyChanges, "This version edits MoMo memory online, without a second offline mutation engine")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        XCTAssertEqual(restored.memories.first?.id, memory.id)
        XCTAssertNotNil(restored.lastSourcesSent)
    }

    func testMemoryRefreshAndUploadReportIndependentFailures() async throws {
        let (sync, root, archive, _) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        MemoryResponse.state.rejectSources = true
        await sync.refresh()
        let lastRead = try XCTUnwrap(sync.lastSynced)
        let noteID = try XCTUnwrap(sync.memories.first?.id)
        XCTAssertNil(sync.failure)
        XCTAssertNotNil(sync.sourceDeliveryFailure)
        XCTAssertGreaterThan(sync.pendingSources, 0)

        MemoryResponse.state.rejectMemories = true
        await sync.refresh()
        XCTAssertNotNil(sync.failure)
        XCTAssertNotNil(sync.sourceDeliveryFailure)
        XCTAssertEqual(sync.memories.first?.id, noteID)
        XCTAssertEqual(sync.lastSynced, lastRead)

        MemoryResponse.state.rejectSources = false
        try await sync.synchronize(includeMemories: false)
        XCTAssertNil(sync.sourceDeliveryFailure)
        XCTAssertEqual(sync.pendingSources, 0)
        XCTAssertNotNil(sync.failure, "A recording receipt cannot confirm a memory refresh")
        MemoryResponse.state.rejectMemories = false
        await sync.refresh()
        XCTAssertNil(sync.failure)
    }
    func testPendingUntranscribedRecordingDoesNotBlockOlderTranscriptDelivery() async throws {
        let (sync, root, archive, _) = try fixture()
        let fingerprint = ContentHash.sha256(Data("pending-sync-test".utf8))
        sync.configurationFingerprint = fingerprint
        let audio = Self.makeWAVFixture()
        func deliver(sessionID: UUID, anchor: Date) async throws {
            let envelope = try ManifestEnvelope(manifest: ChunkManifest(
                sessionID: sessionID, epochID: UUID(), chunkID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests",
                sequence: 0, frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000, wallClockAnchor: anchor,
                timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
                byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sealedAt: anchor, sourceKind: .fixture))
            let file = root.appendingPathComponent(UUID().uuidString)
            try audio.write(to: file)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
        }
        let transcribedSession = UUID()
        try await deliver(sessionID: transcribedSession, anchor: Date(timeIntervalSince1970: 1_790_000_000))
        let claimed = try await archive.claimAnalysisJob(configurationHash: fingerprint)
        let ticket = try XCTUnwrap(claimed)
        _ = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "已经转写完成的录音")
        ])
        // Newer recording whose only recognition result was punctuation (version == 1, spans == []).
        let punctuationSession = UUID()
        try await deliver(sessionID: punctuationSession, anchor: Date(timeIntervalSince1970: 1_790_000_050))
        let claimedPunctuation = try await archive.claimAnalysisJob(configurationHash: fingerprint)
        let punctuationTicket = try XCTUnwrap(claimedPunctuation)
        _ = try await archive.commitTranscript(ticket: punctuationTicket, spans: [
            TranscriptSpan(chunkID: punctuationTicket.chunkID, frames: punctuationTicket.manifest.frames, text: "，。")
        ])
        // Newest recording without any transcript version yet (appears first on recordingsPage).
        let pendingSession = UUID()
        try await deliver(sessionID: pendingSession, anchor: Date(timeIntervalSince1970: 1_790_000_100))
        await sync.refresh()
        XCTAssertNil(sync.failure)
        XCTAssertEqual(sync.pendingSources, 0)
        let sourcePrefix = archive.libraryInstanceID.uuidString.lowercased() + "/"
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, [sourcePrefix + pendingSession.uuidString.lowercased(), sourcePrefix + transcribedSession.uuidString.lowercased()])
        let pending = try XCTUnwrap(MemoryResponse.state.sourcePayloads.first)
        XCTAssertTrue(pending.spans.isEmpty)
        XCTAssertEqual(pending.pendingTranscriptionRanges, [.init(start: 1_790_000_100, end: 1_790_000_100.1)])
        let claimedAnalysis = try await archive.claimEpochAnalysis(configurationFingerprint: fingerprint,
            sessionID: pendingSession, expectedGeneration: pending.generation)
        let analysis = try XCTUnwrap(claimedAnalysis)
        let frames = try XCTUnwrap(analysis.inputs.first?.envelope.manifest.frames)
        try await archive.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [frames],
            noSpeechCoverage: [frames], checkpoint: nil, waitingForMoreAudio: true)
        await sync.refresh()
        XCTAssertNil(sync.failure)
        let finished = try XCTUnwrap(MemoryResponse.state.sourcePayloads.last)
        XCTAssertEqual(finished.sourceID, pending.sourceID)
        XCTAssertEqual(finished.version, pending.version)
        XCTAssertEqual(finished.textSha256, pending.textSha256)
        XCTAssertEqual(finished.pendingTranscriptionRanges, [])
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MemoryResponse.self]; return config
    }
    private func fixture() throws -> (PhoneContextSync, URL, ArchiveStore, AgentConnection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoNativeMemory-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let url = URL(string: "http://127.0.0.1:8765")!
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: url, dataURL: url)
        MemoryResponse.state.reset(connection.workspaceID)
        let sync = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        addTeardownBlock { [weak sync] in await sync?.background() }
        return (sync, root, archive, connection)
    }
    private static func makeWAVFixture() -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(3236); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(3200); data.append(Data(repeating: 0, count: 3200))
        return data
    }
}
private final class MemoryResponse: URLProtocol, @unchecked Sendable {
    static let state = MemoryResponses()
    private let cancellationLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.state.receive(request)
        let respond: @Sendable () -> Void = { [self] in
            guard !cancellationLock.withLock({ stopped }) else { return }
            let headers = code == 429 ? ["Content-Type":"application/json", "Retry-After":"60"] : ["Content-Type":"application/json"]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        if !Self.state.holdResponse(request, respond: respond) { respond() }
    }
    override func stopLoading() { cancellationLock.withLock { stopped = true } }
}
private final class MemoryResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var workspace = UUID(), count = 0, synced: [String] = []
    private var summaryRevision: String?
    private var payloads: [SourceEnvelope] = []
    private var rejected = false
    private var memoriesRejected = false
    private var statusRejected = false
    private var forgetAllowed = false
    private var forgotten = false
    private var sourceCount = 0
    private var sourceStatus: Int?
    private var waitingForStatus: XCTestExpectation?
    private var heldStatus: (@Sendable () -> Void)?
    private var waitingForSource: XCTestExpectation?
    private var heldResponse: (@Sendable () -> Void)?
    private var waitingForMemory: XCTestExpectation?
    private var heldMemory: (@Sendable () -> Void)?
    func holdNextMemory(_ waiting: XCTestExpectation) { lock.withLock { waitingForMemory = waiting } }
    func holdNextStatus(_ waiting: XCTestExpectation) { lock.withLock { waitingForStatus = waiting } }
    func holdNextSource(_ waiting: XCTestExpectation) { lock.withLock { waitingForSource = waiting } }
    func holdResponse(_ request: URLRequest, respond: @escaping @Sendable () -> Void) -> Bool {
        if request.url?.path == "/v1/status" {
            return lock.withLock {
                guard let waitingForStatus else { return false }
                self.waitingForStatus = nil; heldStatus = respond; waitingForStatus.fulfill(); return true
            }
        }
        if request.url?.path == "/v1/memories" {
            return lock.withLock {
                guard let waitingForMemory else { return false }
                self.waitingForMemory = nil; heldMemory = respond; waitingForMemory.fulfill(); return true
            }
        }
        guard request.url?.path == "/v1/sources", request.httpMethod == "POST" else { return false }
        return lock.withLock {
            guard let waitingForSource else { return false }
            self.waitingForSource = nil; heldResponse = respond
            waitingForSource.fulfill()
            return true
        }
    }
    func releaseSource() {
        let response = lock.withLock { let response = heldResponse; heldResponse = nil; return response }
        response?()
    }
    func releaseMemory() {
        let response = lock.withLock { let response = heldMemory; heldMemory = nil; return response }
        response?()
    }
    var sourceAttempts: Int { lock.withLock { sourceCount } }
    var sourceFailureStatus: Int? {
        get { lock.withLock { sourceStatus } }
        set { lock.withLock { sourceStatus = newValue } }
    }
    func releaseStatus() {
        let response = lock.withLock { let response = heldStatus; heldStatus = nil; return response }
        response?()
    }
    var rejectStatus: Bool {
        get { lock.withLock { statusRejected } }
        set { lock.withLock { statusRejected = newValue } }
    }
    var allowForget: Bool {
        get { lock.withLock { forgetAllowed } }
        set { lock.withLock { forgetAllowed = newValue } }
    }
    var rejectSources: Bool {
        get { lock.withLock { rejected } }
        set { lock.withLock { rejected = newValue } }
    }
    var rejectMemories: Bool {
        get { lock.withLock { memoriesRejected } }
        set { lock.withLock { memoriesRejected = newValue } }
    }
    var requests: Int { lock.withLock { count } }
    var syncedSourceIDs: [String] { lock.withLock { synced } }
    var sourcePayloads: [SourceEnvelope] { lock.withLock { payloads } }
    func reset(_ workspace: UUID) { lock.withLock {
        self.workspace = workspace; count = 0; synced = []; payloads = []; summaryRevision = nil
        rejected = false; memoriesRejected = false; statusRejected = false; forgetAllowed = false; forgotten = false; sourceCount = 0
        waitingForSource = nil; heldResponse = nil; waitingForMemory = nil; heldMemory = nil
        waitingForStatus = nil; heldStatus = nil; sourceStatus = nil
    } }
    func receive(_ request: URLRequest) -> (Int, String) {
        lock.withLock {
            count += 1
            if request.url?.path == "/v1/sources", request.httpMethod == "POST" {
                sourceCount += 1
                if let sourceStatus { return (sourceStatus, "{}") }
            }
            if request.url?.path == "/v1/summaries", request.httpMethod == "POST",
               let body = request.BodyData,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let revision = json["revision"] as? String {
                summaryRevision = revision
                return (200, "{\"id\":\"summary-fixture\",\"revision\":\"\(revision)\",\"state\":\"pending\"}")
            }
            if request.url?.path == "/v1/summaries", request.httpMethod == "GET", let revision = summaryRevision {
                return (200, "{\"id\":\"summary-fixture\",\"revision\":\"\(revision)\",\"state\":\"done\",\"text\":\"团队决定周五交付。\"}")
            }
            if request.url?.path == "/v1/status" {
                if statusRejected { return (503, "{}") }
                return (200, "{\"workspace_id\":\"\(workspace)\",\"source_sync\":true,\"memory_writer\":\"SuperAgent\"}")
            }
            if request.url?.path == "/v1/sources", rejected { return (503, "{}") }
            if request.url?.path == "/v1/sources", request.httpMethod == "POST",
               let body = request.BodyData,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let lib = json["library_id"] as? String, let sess = json["session_id"] as? String,
               let gen = json["generation"] as? Int, let ver = json["version"] as? Int,
               let sha = json["text_sha256"] as? String, let del = json["deleted"] as? Bool {
                let sourceID = "\(lib)/\(sess)"
                synced.append(sourceID)
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let envelope = try? decoder.decode(SourceEnvelope.self, from: body) { payloads.append(envelope) }
                let rev = "\(gen):\(ver):\(sha):\(del ? 1 : 0)"
                return (200, "{\"source_id\":\"\(sourceID)\",\"source_revision\":\"\(rev)\",\"revision\":1}")
            }
            if request.url?.path == "/v1/memories" {
                if memoriesRejected { return (503, "{}") }
                if forgotten { return (200, #"{"revision":2,"next_cursor":null,"items":[]}"#) }
                return (200, #"{"revision":1,"next_cursor":null,"items":[{"id":"momo-memory-fixture","text":"下周五发方案","kind":"memory","basis":"momo","status":"current","revision":1,"evidence":[]}]}"#)
            }
            if request.url?.path == "/v1/memories/forget", forgetAllowed { forgotten = true; return (200, "{}") }
            return (503, "{}")
        }
    }
}
private extension URLRequest {
    var BodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
