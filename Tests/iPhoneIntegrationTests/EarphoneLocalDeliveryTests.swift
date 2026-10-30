import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

final class EarphoneLocalDeliveryTests: XCTestCase {
    private var root: URL!
    private let deviceID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EarphoneLocalDelivery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSealedChunksAndEpochEndReachTheArchiveAndLeaveNoPendingReceipts() async throws {
        let (store, archive, delivery) = try await makeDelivery()
        let session = UUID(), epoch = UUID()
        try await seal(seconds: 2, session: session, epoch: epoch, store: store)
        try await store.recordEpochEnded(CaptureEpochEnded(sessionID: session, epochID: epoch,
            sourceDeviceID: deviceID, endFrame: 32_000, reason: .paused))

        let first = try await delivery.deliver(capturingSessionID: session)
        XCTAssertEqual(first.chunkIDs.count, 2)
        XCTAssertEqual(first.events, 1)
        XCTAssertNil(first.deletionAwaitingStop)
        let pendingChunks = try await store.pendingChunkCount()
        let pendingReceipts = try await archive.pendingReceiptCount()
        XCTAssertEqual(pendingChunks, 0)
        // Receipts are applied on both sides, so no watch is ever asked to confirm them.
        XCTAssertEqual(pendingReceipts, 0)

        let again = try await delivery.deliver(capturingSessionID: session)
        XCTAssertFalse(again.changed)
    }

    func testDeletingTheCapturingSessionWaitsForTheStopBarrier() async throws {
        let (store, archive, delivery) = try await makeDelivery()
        let session = UUID(), epoch = UUID()
        try await seal(seconds: 1, session: session, epoch: epoch, store: store)
        _ = try await delivery.deliver(capturingSessionID: session)
        _ = try await archive.deleteSession(id: session)

        let capturing = try await delivery.deliver(capturingSessionID: session)
        XCTAssertEqual(capturing.deletionAwaitingStop, session)
        let stillPending = try await archive.pendingDeletions()
        XCTAssertEqual(stillPending.map(\.sessionID), [session])

        let stopped = try await delivery.deliver(capturingSessionID: nil)
        XCTAssertNil(stopped.deletionAwaitingStop)
        let pending = try await archive.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testWatchSessionDeletionsStayWithTheWatch() async throws {
        let (_, archive, delivery) = try await makeDelivery()
        let watchSession = UUID()
        _ = try await archive.deleteSession(id: watchSession)
        _ = try await delivery.deliver(capturingSessionID: nil)
        let pending = try await archive.pendingDeletions()
        XCTAssertEqual(pending.map(\.sessionID), [watchSession])
    }

    private func makeDelivery() async throws -> (RecordingStore, ArchiveStore, EarphoneLocalDelivery) {
        let store = try RecordingStore(rootURL: root.appendingPathComponent("Ledger"))
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("Archive"), receiverDeviceID: deviceID)
        let delivery = EarphoneLocalDelivery(store: store, archive: archive, deviceID: deviceID,
                                             stagingURL: root.appendingPathComponent("Staging"))
        try await delivery.bindReceiver()
        return (store, archive, delivery)
    }

    private func seal(seconds: Int, session: UUID, epoch: UUID, store: RecordingStore) async throws {
        try await store.saveIntent(.recording, sessionID: session)
        try await store.beginEpoch(sessionID: session, epochID: epoch, sourceDeviceID: deviceID)
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("pcm-\(epoch)"),
            sessionID: session, epochID: epoch, sourceDeviceID: deviceID, sourceBuild: "tests",
            sourceKind: .phone, sampleRate: 16_000, targetFrames: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_800_000_000), timezoneOffset: 0)
        var chunks = try writer.append((0..<(16_000 * seconds)).map { Int16($0 % 200 - 100) })
        if let last = try writer.finish() { chunks.append(last) }
        for chunk in chunks { _ = try await store.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope) }
    }
}
