import AVFoundation
import Foundation
import XCTest
import MoMoAgentClient
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

    /// Full dual-side live acceptance test exercising REAL iPhone App (`ArchiveStore` + `AudioUploadCoordinator`
    /// + `AgentClient`) <-> REAL Mac `AccessService` <-> REAL `ContextService` (`MacAudioPipeline` +
    /// `VoiceprintStore`) <-> REAL Apple Silicon Native Core ML (`SileroVAD` + `MOSS 0.9B` + `ReDimNet2+`)
    /// using REAL human multi-speaker Chinese + English audio recordings.
    ///
    /// Runs when `MOMO_LIVE_MAC_E2E_CONFIG` points to the live stack JSON produced by `live_mac_stack.py`.
    func testLiveDualSideRealHumanAudioEndToEnd() async throws {
        guard let configPath = ProcessInfo.processInfo.environment["MOMO_LIVE_MAC_E2E_CONFIG"],
              !configPath.isEmpty else {
            throw XCTSkip("Set MOMO_LIVE_MAC_E2E_CONFIG to run live dual-side real-audio acceptance against Mac backend.")
        }
        struct LiveConfig: Decodable {
            struct Fixtures: Decodable {
                let session1_zh4_wav: String
                let session2_bilingual_wav: String
                let owner_m4a: String
            }
            let public_data_url: String
            let phone_token: String
            let assistant_id: String
            let paired_device_id: String
            let fixtures: Fixtures
        }
        let cfg = try JSONDecoder().decode(LiveConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        let dataURL = try XCTUnwrap(URL(string: cfg.public_data_url))
        let assistantID = try XCTUnwrap(UUID(uuidString: cfg.assistant_id))
        let deviceID = try XCTUnwrap(UUID(uuidString: cfg.paired_device_id))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoDualSideLive-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        let client = try AgentClient(baseURL: dataURL, credential: cfg.phone_token, assistantID: assistantID)

        var transcriptUpdateCallbacks = 0
        let uploader = AudioUploadCoordinator(
            archive: archive,
            deviceID: deviceID,
            dataClientProvider: { client },
            onTranscriptsUpdated: { transcriptUpdateCallbacks += 1 }
        )

        func loadPCM16(_ path: String) throws -> [Int16] {
            let file = try AVAudioFile(
                forReading: URL(fileURLWithPath: path),
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let frameCount = AVAudioFrameCount(file.length)
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            let ptr = try XCTUnwrap(buf.int16ChannelData?[0])
            return Array(UnsafeBufferPointer(start: ptr, count: n))
        }

        func ingestRealWavAsWatchChunks(path: String, sessionID: UUID, wallClock: Date, chunkSeconds: Int = 30) async throws -> [UUID] {
            let pcm = try loadPCM16(path)
            let targetFrames = chunkSeconds * 16_000
            var writer = try PCM16SegmentWriter(
                directory: root.appendingPathComponent("watch-\(sessionID.uuidString)"),
                sessionID: sessionID,
                epochID: UUID(),
                sourceDeviceID: UUID(),
                sourceBuild: "real-watch-e2e",
                sourceKind: .watch,
                targetFrames: targetFrames,
                wallClockAnchor: wallClock,
                timezoneOffset: 28_800
            )
            var produced = try writer.append(pcm)
            if let tail = try writer.finish() {
                produced.append(tail)
            }
            var chunkIDs: [UUID] = []
            var receipts: [Receipt] = []
            for item in produced {
                let res = try await archive.commitReceivedChunk(
                    archive.inbox.preserve(fileURL: item.audioURL, envelope: item.envelope)
                )
                switch res {
                case .accepted(let r), .restored(let r), .duplicate(let r):
                    receipts.append(r)
                    chunkIDs.append(item.envelope.manifest.chunkID)
                default:
                    XCTFail("Unexpected chunk commit result: \(res)")
                }
            }
            _ = try await archive.applyReceipts(receipts.map { ReceiptApplied(receipt: $0) })
            return chunkIDs
        }

        func waitUntilTranscribed(sessionID: UUID, timeoutSec: TimeInterval = 120) async throws -> (document: TranscriptDocument, locations: [UUID: TranscriptSpanLocation]) {
            let deadline = Date().addingTimeInterval(timeoutSec)
            while Date() < deadline {
                await uploader.syncRemoteTranscriptsFromMac(force: false)
                if let snap = try? await archive.transcriptSnapshot(sessionID: sessionID),
                   !snap.document.spans.isEmpty {
                    let sum = try await archive.recordingSummary(sessionID: sessionID)
                    if sum.transcriptionState == .transcribed {
                        return snap
                    }
                }
                try await Task.sleep(for: .milliseconds(600))
            }
            XCTFail("Timed out waiting for Mac Core ML transcript to sync back to iPhone for session \(sessionID)")
            return try await archive.transcriptSnapshot(sessionID: sessionID)
        }

        // =========================================================================
        // 1. REAL SESSION 1: 56.86s REAL 4-speaker Chinese conversation (2 Watch chunks)
        // =========================================================================
        let session1ID = UUID()
        let s1WallClock = Date().addingTimeInterval(-3600)
        let tStart = Date()
        let s1Chunks = try await ingestRealWavAsWatchChunks(
            path: cfg.fixtures.session1_zh4_wav,
            sessionID: session1ID,
            wallClock: s1WallClock,
            chunkSeconds: 30
        )
        XCTAssertEqual(s1Chunks.count, 2, "56.86s real Chinese conversation should split into 2 Watch chunks")

        // Verify iPhone retention protects unuploaded real audio even 40 days past sealing!
        let futureNow = Date().addingTimeInterval(40 * 86_400)
        let blocked = try await archive.applyRetention(now: futureNow, replayFloors: [:], limit: 16)
        XCTAssertTrue(blocked.isEmpty, "Unuploaded real audio must never be pruned before Mac confirms upload")

        // Real iPhone AudioUploadCoordinator drains queue -> AccessService -> ContextService -> Core ML!
        await uploader.drainUploadQueue()
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.uploadedCount, 2)
        XCTAssertNil(uploader.lastError)

        let snap1 = try await waitUntilTranscribed(sessionID: session1ID, timeoutSec: 120)
        let s1Elapsed = Date().timeIntervalSince(tStart)
        let s1Speakers = Set(snap1.document.spans.compactMap(\.speaker))
        print("\n[LIVE REAL-DATA] === SESSION 1 (0-four-speakers-zh.wav, 56.86s, 4 real Chinese speakers) ===")
        print("[LIVE REAL-DATA] End-to-end (iPhone upload -> AccessService -> CoreML -> iPhone SQLite): \(String(format: "%.2f", s1Elapsed))s, spans=\(snap1.document.spans.count), distinct_speakers=\(s1Speakers.sorted())")
        for sp in snap1.document.spans {
            print("[LIVE REAL-DATA]   [\(sp.speaker ?? "?")] \(sp.text)")
        }
        XCTAssertGreaterThanOrEqual(snap1.document.spans.count, 4, "Real 4-speaker Chinese recording should produce multiple spans")
        XCTAssertGreaterThanOrEqual(s1Speakers.count, 3, "MOSS Core ML should separate at least 3 distinct real speakers in 4-speaker audio")

        // Confirm Timeline UI summary & window settled cleanly on iPhone
        let s1Summary = try await archive.recordingSummary(sessionID: session1ID)
        XCTAssertEqual(s1Summary.transcriptionState, .transcribed)
        let s1Timeline = try await archive.timelineWindow(containing: snap1.document.source(for: snap1.document.spans[0]))
        XCTAssertEqual(s1Timeline?.state, .complete)

        // =========================================================================
        // 2. REAL IPHONE ONBOARDING: Enroll Owner ("我") via AAC .m4a (repo real Chinese voice)
        // =========================================================================
        let ownerProfile = try await client.createVoiceprintProfile(name: "我", isOwner: true, aliases: ["主人"])
        let ownerM4AData = try Data(contentsOf: URL(fileURLWithPath: cfg.fixtures.owner_m4a))
        XCTAssertLessThan(ownerM4AData.count, 512 * 1024, "AAC voiceprint enrollment clip must fit inside Relay 512KB limit")
        let enrollResp = try await client.enrollVoiceprintSample(
            profileID: ownerProfile.id,
            audioData: ownerM4AData,
            filename: "owner.m4a",
            sourceDevice: "iphone"
        )
        XCTAssertEqual(enrollResp.profile.sampleCount, 1)
        print("[LIVE REAL-DATA] Owner AAC enrolled on ANE: bytes=\(ownerM4AData.count), clean=\(String(format: "%.2f", enrollResp.quality.cleanSeconds ?? 0))s, latency=\(String(format: "%.1f", enrollResp.quality.latencyMs ?? 0))ms")

        // =========================================================================
        // 3. REAL IPHONE CLICK-TO-LOCK on a real Chinese speaker from Session 1
        // =========================================================================
        // Pick the real Chinese speaker with the most text in the first 25s of Session 1 (guaranteed to reappear in Session 2's 0..28s excerpt!)
        let earlySpans = snap1.document.spans.filter { sp in
            guard let loc = snap1.locations[sp.id] else { return false }
            return loc.recordedAt < s1WallClock.addingTimeInterval(25)
        }
        let candidateSpans = earlySpans.isEmpty ? snap1.document.spans : earlySpans
        let speakerCharCounts = Dictionary(grouping: candidateSpans, by: { $0.speaker ?? "" })
            .mapValues { $0.reduce(0) { $0 + $1.text.count } }
        let dominantSpeaker = try XCTUnwrap(speakerCharCounts.max(by: { $0.value < $1.value })?.key)
        let targetSpan = try XCTUnwrap(candidateSpans.first(where: { $0.speaker == dominantSpeaker }))
        let source1ID = "\(archive.libraryInstanceID.uuidString.lowercased())/\(session1ID.uuidString.lowercased())"
        let bindRes = try await client.bindTranscriptSpeaker(
            sourceID: source1ID,
            spanIDs: [targetSpan.id.uuidString.lowercased()],
            clusterKey: nil,
            profileID: nil,
            targetName: "林总",
            isOwner: false,
            enrollVoiceprint: true,
            rematchHistory: true,
            scope: "cluster"
        )
        XCTAssertTrue(bindRes.success)
        XCTAssertTrue(bindRes.enrolledVoiceprint, "Real Chinese speaker cluster should have enough clean speech to enroll voiceprint!")
        let linProfileID = try XCTUnwrap(bindRes.profileId)
        print("[LIVE REAL-DATA] Click-to-lock bound '\(dominantSpeaker)' -> '林总' (profile=\(linProfileID.prefix(8)), enrolled_samples=\(bindRes.enrolledSamples), updated_spans=\(bindRes.updatedSpanCount), rematch_ms=\(String(format: "%.2f", bindRes.rematch?.elapsedMs ?? 0))ms)")

        // Pull WITHOUT force=true! Proves Mac sources.revision bumped and iPhone auto-synced the rename!
        await uploader.syncRemoteTranscriptsFromMac(force: false)
        let snap1AfterBind = try await archive.transcriptSnapshot(sessionID: session1ID)
        XCTAssertTrue(snap1AfterBind.document.spans.contains(where: { $0.speaker == "林总" }), "iPhone ArchiveStore must automatically reflect '林总' via revision bump without force!")

        // =========================================================================
        // 4. REAL SESSION 2: 57s REAL bilingual multi-speaker recording (Owner + 2 English + Session-1 Chinese speakers)
        // =========================================================================
        let session2ID = UUID()
        let t2Start = Date()
        let s2Chunks = try await ingestRealWavAsWatchChunks(
            path: cfg.fixtures.session2_bilingual_wav,
            sessionID: session2ID,
            wallClock: Date().addingTimeInterval(-1800),
            chunkSeconds: 30
        )
        XCTAssertEqual(s2Chunks.count, 2)
        await uploader.drainUploadQueue()
        XCTAssertEqual(uploader.pendingCount, 0)

        let snap2 = try await waitUntilTranscribed(sessionID: session2ID, timeoutSec: 120)
        let s2Elapsed = Date().timeIntervalSince(t2Start)
        let s2Speakers = Set(snap2.document.spans.compactMap(\.speaker))
        print("\n[LIVE REAL-DATA] === SESSION 2 (Owner real ZH + 2 real EN + Session-1 real ZH, ~57s) ===")
        print("[LIVE REAL-DATA] End-to-end: \(String(format: "%.2f", s2Elapsed))s, spans=\(snap2.document.spans.count), speakers=\(s2Speakers.sorted())")
        for sp in snap2.document.spans {
            print("[LIVE REAL-DATA]   [\(sp.speaker ?? "?")] \(sp.text)")
        }
        XCTAssertTrue(s2Speakers.contains("我"), "Enrolled real Owner ('我') must auto-lock in Session 2! Found: \(s2Speakers)")
        XCTAssertTrue(s2Speakers.contains("林总"), "Click-to-locked real Chinese speaker ('林总') from Session 1 must auto-lock in Session 2! Found: \(s2Speakers)")
        XCTAssertTrue(s2Speakers.contains(where: { $0 != "我" && $0 != "林总" }), "Unknown real English/Chinese speakers must remain anonymous, not falsely merged!")

        // =========================================================================
        // 5. REAL IPHONE NEGATIVE REJECTION ("这不是 林总") + AUTOMATIC SYNC BACK
        // =========================================================================
        let source2ID = "\(archive.libraryInstanceID.uuidString.lowercased())/\(session2ID.uuidString.lowercased())"
        let s2LinSpan = try XCTUnwrap(snap2.document.spans.first(where: { $0.speaker == "林总" }))
        let rejRes = try await client.rejectSpeakerMatch(
            sourceID: source2ID,
            profileID: linProfileID,
            speakerName: "林总",
            spanIDs: [s2LinSpan.id.uuidString.lowercased()],
            clusterKey: nil
        )
        XCTAssertTrue(rejRes.success)
        XCTAssertGreaterThanOrEqual(rejRes.rejectedVectors, 1)
        await uploader.syncRemoteTranscriptsFromMac(force: false)
        let snap2AfterRej = try await archive.transcriptSnapshot(sessionID: session2ID)
        let rejSpanOnPhone = try XCTUnwrap(snap2AfterRej.document.spans.first(where: { $0.id == s2LinSpan.id }))
        XCTAssertNotEqual(rejSpanOnPhone.speaker, "林总", "Rejected speaker label must clear on iPhone automatically via revision bump!")
        print("[LIVE REAL-DATA] Negative rejection cleared '林总' on BOTH Mac and iPhone cleanly (rejected_vectors=\(rejRes.rejectedVectors))")

        // =========================================================================
        // 6. REMOTE SETTINGS PATCH, REAL AAC DICTATION, RANGE 206 STREAMING, RETENTION
        // =========================================================================
        var remoteSettings = try await client.speechSettings()
        remoteSettings.customHotwords = ["墨墨助手", "Core ML", "声纹锁定"]
        let patchedSettings = try await client.updateSpeechSettings(remoteSettings)
        XCTAssertEqual(patchedSettings.customHotwords, ["墨墨助手", "Core ML", "声纹锁定"])

        let dictation = try await client.dictateAudio(ownerM4AData, filename: "dictate.m4a")
        print("[LIVE REAL-DATA] iPhone AAC Dictation -> Mac MOSS Core ML: '\(dictation.text)' (\(String(format: "%.2f", dictation.elapsedSec))s)")
        XCTAssertGreaterThanOrEqual(dictation.text.count, 4)

        var streamReq = try client.audioStreamURLRequest(sourceID: source1ID)
        streamReq.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        let (streamData, streamResp) = try await URLSession.shared.data(for: streamReq)
        let httpResp = try XCTUnwrap(streamResp as? HTTPURLResponse)
        XCTAssertEqual(httpResp.statusCode, 206, "AccessService must forward Range 206 Partial Content")
        XCTAssertEqual(streamData.count, 2048)

        // Confirmed uploaded real audio can now be reclaimed by retention!
        let reclaimed = try await archive.applyRetention(now: futureNow, replayFloors: [:], limit: 16)
        XCTAssertEqual(Set(reclaimed), Set(s1Chunks + s2Chunks))
        XCTAssertGreaterThanOrEqual(transcriptUpdateCallbacks, 2)
        print("[LIVE REAL-DATA] ALL DUAL-SIDE REAL HUMAN AUDIO CHECKS PASSED 100%!")
    }
}
