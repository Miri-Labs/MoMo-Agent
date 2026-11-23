import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class MacAudioRelayIntegrationTests: XCTestCase {
    func testRetentionProtectsUnuploadedChunksAndCachesMultiChunkMacTranscripts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoMacRelay-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())

        // Stage a 2-chunk session recorded 40 days ago (past default 30-day retention).
        let oldDate = Date().addingTimeInterval(-40 * 86_400)
        let sessionID = UUID()
        let epochID = UUID()
        let sourceDeviceID = UUID()
        var writer = try PCM16SegmentWriter(
            directory: root.appendingPathComponent("writer"),
            sessionID: sessionID,
            epochID: epochID,
            sourceDeviceID: sourceDeviceID,
            sourceBuild: "relay-test",
            sourceKind: .phone,
            targetFrames: 16_000,
            wallClockAnchor: oldDate,
            timezoneOffset: 28_800
        )
        let produced1 = try XCTUnwrap(writer.append([Int16](repeating: 100, count: 16_000)).first)
        let produced2 = try XCTUnwrap(writer.append([Int16](repeating: 120, count: 16_000)).first)
        let r1 = try await archive.commitReceivedChunk(
            archive.inbox.preserve(fileURL: produced1.audioURL, envelope: produced1.envelope)
        )
        let r2 = try await archive.commitReceivedChunk(
            archive.inbox.preserve(fileURL: produced2.audioURL, envelope: produced2.envelope)
        )
        // Apply Watch/Earphone delivery receipts so retention eligibility depends purely on Mac upload state.
        let receipts: [Receipt] = [r1, r2].compactMap { result in
            switch result {
            case .accepted(let receipt), .restored(let receipt), .duplicate(let receipt):
                return receipt
            default:
                return nil
            }
        }
        XCTAssertEqual(receipts.count, 2)
        _ = try await archive.applyReceipts(receipts.map { ReceiptApplied(receipt: $0) })

        // 1. Pending upload queue returns both chunks with chronological per-session seq (0, 1) and distinct wall-clock timestamps.
        let pending = try await archive.pendingMacAudioUploads(limit: 8).sorted(by: { $0.chunkSeq < $1.chunkSeq })
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].chunkSeq, 0)
        XCTAssertEqual(pending[1].chunkSeq, 1)
        XCTAssertEqual(pending[0].sourceKind, "earphone")
        XCTAssertEqual(pending[1].recordedAt.timeIntervalSince(pending[0].recordedAt), 1.0, accuracy: 0.05)

        // 2. Retention MUST NOT delete unuploaded chunks even 40 days after sealing (past 7-day default retention)!
        let futureNow = Date().addingTimeInterval(40 * 86_400)
        let removedBeforeUpload = try await archive.applyRetention(now: futureNow, replayFloors: [:], limit: 16)
        XCTAssertTrue(removedBeforeUpload.isEmpty, "Unuploaded chunks must be protected from retention pruning.")

        // 3. Mark both chunks uploaded & confirmed by Mac.
        let sourceID = "\(archive.libraryInstanceID.uuidString.lowercased())/\(sessionID.uuidString.lowercased())"
        for item in pending {
            try await archive.markMacAudioChunkUploaded(
                chunkID: item.chunkID,
                remoteSHA256: item.audioSHA256,
                remoteSourceID: sourceID
            )
        }
        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.uploaded, 2)
        let macSessions = try await archive.macAuthoritativeSessionIDs()
        XCTAssertTrue(macSessions.contains(sessionID))

        // 4. Cache Mac-authoritative MOSS + ReDimNet2+ transcript (preserving Mac generation=1, version=2).
        let span1ID = UUID()
        let span2ID = UUID()
        try await archive.cacheMacRemoteTranscript(
            sessionID: sessionID,
            spans: [
                MacRemoteTranscriptSpanInput(
                    id: span1ID,
                    text: "下午三点我们在会议室同步 Core ML 方案。",
                    recordedAt: pending[0].recordedAt,
                    endAt: pending[0].recordedAt.addingTimeInterval(0.9),
                    speaker: "我",
                    isOwner: true,
                    timezoneOffset: 28_800
                ),
                MacRemoteTranscriptSpanInput(
                    id: span2ID,
                    text: "好的，我把性能数据整理好发给大家。",
                    recordedAt: pending[1].recordedAt,
                    endAt: pending[1].recordedAt.addingTimeInterval(0.9),
                    speaker: "Alex",
                    isOwner: false,
                    timezoneOffset: 28_800
                ),
            ],
            macGeneration: 1,
            macVersion: 2
        )
        let snapshot = try await archive.transcriptSnapshot(sessionID: sessionID)
        XCTAssertEqual(snapshot.document.generation, 1)
        XCTAssertEqual(snapshot.document.version, 2)
        XCTAssertEqual(snapshot.document.spans.count, 2)
        XCTAssertEqual(snapshot.document.spans[0].speaker, "我")
        XCTAssertEqual(snapshot.document.spans[1].speaker, "Alex")
        XCTAssertEqual(snapshot.document.spans[1].chunkID, pending[1].chunkID)

        // Verify Timeline & RecordingSummary reflect complete state (not stuck on "等待 Mac 转录")
        let summary = try await archive.recordingSummary(sessionID: sessionID)
        XCTAssertEqual(summary.transcriptionState, .transcribed)
        let timelineWin = try await archive.timelineWindow(containing: snapshot.document.source(for: snapshot.document.spans[0]))
        XCTAssertEqual(timelineWin?.state, .complete)

        // 5. After upload confirmation, retention is now permitted to reclaim old local audio even with replayFloors: [:].
        let removedAfterUpload = try await archive.applyRetention(now: futureNow, replayFloors: [:], limit: 16)
        XCTAssertEqual(Set(removedAfterUpload), Set(pending.map(\.chunkID)))
    }
}
