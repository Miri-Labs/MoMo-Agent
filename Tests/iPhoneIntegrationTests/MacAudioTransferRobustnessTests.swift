import CryptoKit
import Foundation
import XCTest
import MoMoAgentClient
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

/// Matt Pocock TDD Vertical-Slice Robustness Tests for iPhone -> Mac Audio Transfer Seams.
///
/// Exercises REAL `ArchiveStore`, REAL `AudioUploadCoordinator`, REAL `PhoneContextDelivery`,
/// and REAL `AgentClient` with ONLY the external HTTP wire boundary stubbed via `URLProtocol`.
@MainActor
final class MacAudioTransferRobustnessTests: XCTestCase {
    private final class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buf = [UInt8](repeating: 0, count: 16_384)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buf, maxLength: buf.count)
                    if read > 0 { body.append(buf, count: read) } else { break }
                }
            }
            let (status, headers, data) = Self.handler?(request, body) ?? (500, [:], Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:9999")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeStubClient(
        handler: @escaping @Sendable (URLRequest, Data) -> (Int, [String: String], Data)
    ) throws -> AgentClient {
        StubHTTPProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubHTTPProtocol.self]
        return try AgentClient(
            baseURL: URL(string: "http://127.0.0.1:19876/context")!,
            credential: "test-token-1234",
            assistantID: UUID(),
            configuration: cfg
        )
    }

    private func stagePCMChunk(
        in archive: ArchiveStore,
        root: URL,
        sessionID: UUID,
        seconds: Int,
        wallClock: Date
    ) async throws -> (chunkID: UUID, sha256: String, byteCount: Int64) {
        let frames = seconds * 16_000
        var writer = try PCM16SegmentWriter(
            directory: root.appendingPathComponent("writer-\(UUID().uuidString)"),
            sessionID: sessionID,
            epochID: UUID(),
            sourceDeviceID: UUID(),
            sourceBuild: "robustness-tdd",
            sourceKind: .watch,
            targetFrames: frames,
            wallClockAnchor: wallClock,
            timezoneOffset: 28_800
        )
        // Non-silent 440 Hz sine wave so AAC encoder and VAD see valid audio
        var pcm = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            pcm[i] = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / 16_000.0) * 12_000.0)
        }
        let produced = try XCTUnwrap(writer.append(pcm).first)
        let res = try await archive.commitReceivedChunk(
            archive.inbox.preserve(fileURL: produced.audioURL, envelope: produced.envelope)
        )
        switch res {
        case .accepted(let receipt), .restored(let receipt), .duplicate(let receipt):
            _ = try await archive.applyReceipts([ReceiptApplied(receipt: receipt)])
        default:
            XCTFail("Expected accepted chunk, got \(res)")
        }
        return (
            produced.envelope.manifest.chunkID,
            produced.envelope.manifest.audioSHA256,
            produced.envelope.manifest.byteCount
        )
    }

    nonisolated private static func decodeMeta(from request: URLRequest) -> [String: Any]? {
        guard let b64 = request.value(forHTTPHeaderField: "X-MoMo-Chunk-Meta"),
              let raw = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Slice 2: A newest poison chunk returning HTTP 422 MUST NOT head-of-line block older healthy chunks,
    /// and MUST be marked permanently failed so it does not spin forever.
    func testSlice2PoisonChunkDoesNotHeadOfLineBlockOlderHealthyChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice2-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)

        let older = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-120))
        // Slight pause so newer chunk has strictly greater sealed_at and lands at the head of pending queue
        try await Task.sleep(for: .milliseconds(30))
        let poison = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let poisonID = poison.chunkID.uuidString.lowercased()
        let client = try makeStubClient { req, body in
            guard req.url?.path.hasSuffix("/v1/audio/chunks") == true else {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":0,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":0,\"total_bytes\":0,\"total_mb\":0},\"voiceprint_count\":0}".utf8))
            }
            let meta = Self.decodeMeta(from: req) ?? [:]
            let cid = (meta["chunk_id"] as? String ?? "").lowercased()
            if cid == poisonID {
                let err = Data("{\"error\":{\"code\":\"invalid_audio\",\"message\":\"Corrupt container\"}}".utf8)
                return (422, ["Content-Type": "application/json"], err)
            }
            let actualSha = Self.sha256Hex(body)
            let lib = meta["library_id"] as? String ?? ""
            let sess = meta["session_id"] as? String ?? ""
            let receipt: [String: Any] = [
                "accepted": true,
                "deduplicated": false,
                "chunk_id": cid,
                "source_id": "\(lib)/\(sess)",
                "sha256": actualSha,
                "transcription_status": "pending",
            ]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: receipt))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()

        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.uploaded, 1, "Older healthy chunk must still upload even when newest chunk returns 422!")
        XCTAssertEqual(counts.permanentFailed, 1, "HTTP 422 chunk must be marked permanently failed")
        XCTAssertEqual(counts.pending, 0)
    }

    /// Slice 3 (iPhone side): A receipt with a mismatched SHA-256 MUST be rejected so local audio
    /// is never marked uploaded or eligible for retention pruning.
    func testSlice3TamperedReceiptSHA256IsRejectedAndProtectsLocalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice3-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        let chunk = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let client = try makeStubClient { req, _ in
            let meta = Self.decodeMeta(from: req) ?? [:]
            let cid = (meta["chunk_id"] as? String ?? "").lowercased()
            let receipt: [String: Any] = [
                "accepted": true,
                "deduplicated": false,
                "chunk_id": cid,
                "source_id": "\(meta["library_id"] ?? "")/\(meta["session_id"] ?? "")",
                "sha256": String(repeating: "0", count: 64), // Tampered / mismatched SHA-256!
                "transcription_status": "pending",
            ]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: receipt))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()

        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.uploaded, 0, "Tampered SHA-256 receipt must NEVER mark chunk uploaded!")
        let pruned = try await archive.applyRetention(now: Date().addingTimeInterval(40 * 86_400), replayFloors: [:], limit: 16)
        XCTAssertTrue(pruned.isEmpty, "Retention must continue protecting local audio after rejected receipt")
        XCTAssertFalse(chunk.sha256.isEmpty)
    }

    /// Slice 5: Synced source revisions MUST persist across coordinator restarts so reopening the app
    /// does not re-download unchanged historical transcripts from Mac.
    func testSlice5KnownSourceRevisionsPersistAcrossCoordinatorRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice5-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        let sessionID = UUID()
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: sessionID, seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let sourceID = "\(archive.libraryInstanceID.uuidString.lowercased())/\(sessionID.uuidString.lowercased())"
        let revision = "1:2:abcdef:0"
        let spanID = UUID().uuidString.lowercased()
        let recordedAt = Date().addingTimeInterval(-60).timeIntervalSince1970

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var sourceTextFetches = 0
            func inc() { lock.withLock { sourceTextFetches += 1 } }
            var value: Int { lock.withLock { sourceTextFetches } }
        }
        let counter = Counter()

        let client = try makeStubClient { req, _ in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/v1/transcription/status") {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":1,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":1,\"total_bytes\":1000,\"total_mb\":0.01},\"voiceprint_count\":0}".utf8))
            }
            if path.hasSuffix("/v1/sources") {
                let body: [String: Any] = [
                    "revision": 1,
                    "items": [[
                        "id": sourceID,
                        "revision": revision,
                        "text_sha256": "abcdef",
                        "total_characters": 10,
                        "preview": "测试持久化",
                        "recorded_at": recordedAt,
                    ]],
                ]
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body))
            }
            if path.hasSuffix("/v1/source") {
                counter.inc()
                let body: [String: Any] = [
                    "source_id": sourceID,
                    "source_revision": revision,
                    "text_sha256": "abcdef",
                    "offset": 0,
                    "end": 10,
                    "total_characters": 10,
                    "truncated": false,
                    "text": "[我] 测试持久化",
                    "spans": [[
                        "id": spanID,
                        "recorded_at": recordedAt,
                        "end_at": recordedAt + 0.8,
                        "text": "[我] 测试持久化",
                        "speaker": "我",
                        "is_owner": true,
                        "timezone_offset": 28_800,
                        "citation_url": "momoagent://source/\(sessionID.uuidString.lowercased())/\(spanID)?version=2&generation=1",
                    ]],
                ]
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body))
            }
            return (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }

        // First app session pulls the transcript once.
        let uploader1 = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader1.syncRemoteTranscriptsFromMac(force: false)
        XCTAssertEqual(counter.value, 1)

        // Simulate app restart with a brand-new AudioUploadCoordinator instance on the same ArchiveStore.
        let uploader2 = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader2.syncRemoteTranscriptsFromMac(force: false)
        XCTAssertEqual(counter.value, 1, "Restarted AudioUploadCoordinator must NOT re-download unchanged source revision!")
    }

    /// Slice 6: Oversized PCM16 WAV chunks (> 460 KB, exceeding Relay's 512 KB cap) MUST be automatically
    /// transcoded to compact 16 kHz mono AAC (< 250 KB) with matching SHA-256 before uploading.
    func testSlice6OversizedPCM16ChunkAutoTranscodesToRelaySafeAACBeforeUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice6-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)

        // 30s of 16 kHz mono PCM16 WAV is ~960 KB (exceeds Relay's 512 KB hard cap!)
        let bigChunk = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 30, wallClock: Date().addingTimeInterval(-60))
        XCTAssertGreaterThan(bigChunk.byteCount, 512 * 1024, "Test precondition: raw PCM16 chunk must exceed 512 KB")

        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            var bodySize = 0
            var codec = ""
            var contentType = ""
            var shaMatchesBody = false
            func record(size: Int, codec: String, contentType: String, shaMatches: Bool) {
                lock.withLock {
                    self.bodySize = size
                    self.codec = codec
                    self.contentType = contentType
                    self.shaMatchesBody = shaMatches
                }
            }
        }
        let captured = Captured()

        let client = try makeStubClient { req, body in
            guard req.url?.path.hasSuffix("/v1/audio/chunks") == true else {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":0,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":0,\"total_bytes\":0,\"total_mb\":0},\"voiceprint_count\":0}".utf8))
            }
            let meta = Self.decodeMeta(from: req) ?? [:]
            let actualSha = Self.sha256Hex(body)
            let metaSha = (meta["sha256"] as? String ?? "").lowercased()
            captured.record(
                size: body.count,
                codec: meta["codec"] as? String ?? "",
                contentType: req.value(forHTTPHeaderField: "Content-Type") ?? "",
                shaMatches: actualSha == metaSha
            )
            // Enforce Relay's 512 KB body limit!
            if body.count > 512 * 1024 {
                return (413, ["Content-Type": "application/json"], Data("{\"error\":{\"code\":\"too_large\",\"message\":\"Request body exceeds relay limit\"}}".utf8))
            }
            let receipt: [String: Any] = [
                "accepted": true,
                "deduplicated": false,
                "chunk_id": (meta["chunk_id"] as? String ?? "").lowercased(),
                "source_id": "\(meta["library_id"] ?? "")/\(meta["session_id"] ?? "")",
                "sha256": actualSha,
                "transcription_status": "pending",
            ]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: receipt))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()

        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.uploaded, 1, "Oversized PCM16 chunk must transcode to AAC and succeed within Relay 512 KB cap!")
        XCTAssertLessThan(captured.bodySize, 250 * 1024, "30s AAC upload should be < 250 KB")
        XCTAssertEqual(captured.codec, "aac")
        XCTAssertEqual(captured.contentType, "audio/mp4")
        XCTAssertTrue(captured.shaMatchesBody, "Transcoded AAC header SHA-256 must match actual transmitted bytes")
    }

    /// Slice 2 (401 auth): HTTP 401 triggers `onAuthenticationRequired`, halts pass cleanly,
    /// and does NOT permanently poison the chunk so re-pairing can resume uploading it.
    func testSlice2Unauthorized401TriggersAuthCallbackWithoutPoisoningChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice2Auth-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let client = try makeStubClient { _, _ in
            (401, ["Content-Type": "application/json"], Data("{\"error\":{\"code\":\"unauthorized\",\"message\":\"Device revoked\"}}".utf8))
        }

        var authCallbackCount = 0
        let uploader = AudioUploadCoordinator(
            archive: archive,
            deviceID: deviceID,
            dataClientProvider: { client },
            onAuthenticationRequired: { _ in authCallbackCount += 1 }
        )
        await uploader.drainUploadQueue()

        XCTAssertEqual(authCallbackCount, 1, "HTTP 401 must surface authentication failure immediately")
        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.permanentFailed, 0, "401 must NOT permanently fail the audio chunk")
        XCTAssertEqual(counts.failed, 1)
    }

    /// Slice 5 (Background delivery budget ownership & failure propagation): When Mac returns 503,
    /// `deliverInBackgroundPass()` throws so `PhoneContextDelivery` reports `success == false`
    /// and keeps `BGProcessingTask` scheduled for retry.
    func testSlice5BackgroundDeliveryPropagatesFailureToPhoneContextDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSlice5BG-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let client = try makeStubClient { _, _ in
            (503, ["Content-Type": "application/json"], Data("{\"error\":{\"code\":\"unavailable\",\"message\":\"Mac asleep\"}}".utf8))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        uploader.notePendingUploadArrived()

        var scheduledPendingStates: [Bool] = []
        let finished = expectation(description: "BG delivery completes")
        var bgSuccess: Bool?

        let delivery = PhoneContextDelivery(
            needsDelivery: { uploader.hasPendingWork },
            deliver: { try await uploader.deliverInBackgroundPass() },
            prepare: {},
            suspend: {},
            cancel: { uploader.cancelUpload() },
            schedule: { scheduledPendingStates.append($0) },
            budget: .seconds(10)
        )
        delivery.requestWithSystemGrant(id: UUID()) { success in
            bgSuccess = success
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(bgSuccess, false, "Transient 503 during background upload MUST report failure to PhoneContextDelivery")
        XCTAssertEqual(scheduledPendingStates.last, true, "BGProcessingTask must stay scheduled after transient upload failure")
    }

    /// Review P0 #3: Missing local audio file on disk MUST be isolated as permanent_failed instead of
    /// head-of-line blocking older healthy chunks or pinning `hasPendingWork = true` forever.
    func testReviewP0MissingLocalFileIsIsolatedWithoutBlockingOlderChunks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoP0Missing-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)

        let older = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-120))
        try await Task.sleep(for: .milliseconds(30))
        let missing = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        // Delete the newer chunk's local file on disk to simulate unexpected missing file
        let allPending = try await archive.pendingMacAudioUploads(limit: 8)
        let missingItem = try XCTUnwrap(allPending.first(where: { $0.chunkID == missing.chunkID }))
        try FileManager.default.removeItem(at: missingItem.audioURL)

        let client = try makeStubClient { req, body in
            guard req.url?.path.hasSuffix("/v1/audio/chunks") == true else {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":0,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":0,\"total_bytes\":0,\"total_mb\":0},\"voiceprint_count\":0}".utf8))
            }
            let meta = Self.decodeMeta(from: req) ?? [:]
            let cid = (meta["chunk_id"] as? String ?? "").lowercased()
            let receipt: [String: Any] = [
                "accepted": true, "deduplicated": false, "chunk_id": cid,
                "source_id": "\(meta["library_id"] ?? "")/\(meta["session_id"] ?? "")",
                "sha256": Self.sha256Hex(body), "transcription_status": "pending",
            ]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: receipt))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()

        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.uploaded, 1, "Older healthy chunk \(older.chunkID) must upload even when newer file vanished")
        XCTAssertEqual(counts.permanentFailed, 1, "Vanished local file must be isolated as permanent_failed")
        XCTAssertFalse(uploader.hasPendingWork, "hasPendingWork must clear once only permanentFailed remains")
    }

    /// Review P0 #6: Corrupted local audio file on disk (failing `manifest.audioSHA256`) MUST NEVER
    /// be uploaded to Mac or marked uploaded.
    func testReviewP0CorruptedLocalFileFailsManifestSHA256CheckBeforeUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoP0Corrupt-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        let chunk = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 1, wallClock: Date().addingTimeInterval(-60))

        // Corrupt bytes on disk after archival
        let pendingList = try await archive.pendingMacAudioUploads(limit: 4)
        let item = try XCTUnwrap(pendingList.first(where: { $0.chunkID == chunk.chunkID }))
        try Data("CORRUPTED_LOCAL_AUDIO_BYTES".utf8).write(to: item.audioURL)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var uploads = 0
            func inc() { lock.withLock { uploads += 1 } }
            var value: Int { lock.withLock { uploads } }
        }
        let counter = Counter()
        let client = try makeStubClient { req, _ in
            if req.url?.path.hasSuffix("/v1/audio/chunks") == true { counter.inc() }
            return (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()

        XCTAssertEqual(counter.value, 0, "Corrupted local audio must never be transmitted to Mac!")
        let counts = try await archive.macAudioUploadCounts()
        XCTAssertEqual(counts.uploaded, 0)
        XCTAssertEqual(counts.permanentFailed, 1)
    }

    /// Review P0 #7: Transcoded AAC payload is deterministically cached across retries so attempt 2
    /// sends bit-identical bytes and identical SHA-256 to Mac.
    func testReviewP0TranscodedAACCachedBitIdenticallyAcrossRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoP0CacheAAC-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: UUID(), seconds: 30, wallClock: Date().addingTimeInterval(-60))

        final class AttemptLog: @unchecked Sendable {
            private let lock = NSLock()
            var shas: [String] = []
            func append(_ sha: String) -> Int {
                lock.withLock {
                    shas.append(sha)
                    return shas.count
                }
            }
            var snapshot: [String] { lock.withLock { shas } }
        }
        let log = AttemptLog()

        let client = try makeStubClient { req, body in
            guard req.url?.path.hasSuffix("/v1/audio/chunks") == true else {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":0,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":0,\"total_bytes\":0,\"total_mb\":0},\"voiceprint_count\":0}".utf8))
            }
            let sha = Self.sha256Hex(body)
            let attempt = log.append(sha)
            if attempt == 1 {
                return (503, ["Content-Type": "application/json"], Data("{\"error\":{\"code\":\"unavailable\",\"message\":\"Retry\"}}".utf8))
            }
            let meta = Self.decodeMeta(from: req) ?? [:]
            let receipt: [String: Any] = [
                "accepted": true, "deduplicated": false,
                "chunk_id": (meta["chunk_id"] as? String ?? "").lowercased(),
                "source_id": "\(meta["library_id"] ?? "")/\(meta["session_id"] ?? "")",
                "sha256": sha, "transcription_status": "pending",
            ]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: receipt))
        }

        let uploader = AudioUploadCoordinator(archive: archive, deviceID: deviceID, dataClientProvider: { client })
        await uploader.drainUploadQueue()
        try await archive.resetTransientMacAudioUploadBackoff()
        await uploader.drainUploadQueue()

        let shas = log.snapshot
        XCTAssertEqual(shas.count, 2)
        XCTAssertEqual(shas[0], shas[1], "Retry of transcoded AAC must transmit bit-identical bytes and identical SHA-256!")
        let uploadedAfterRetry = try await archive.macAudioUploadCounts().uploaded
        XCTAssertEqual(uploadedAfterRetry, 1)
    }

    /// Review P1 #12: Mid-pagination HTTP 409 on one active source MUST NOT abort remaining sources
    /// or suppress `onTranscriptsUpdated()` for sources already synced.
    func testReviewP1MidPagination409IsolatesSingleSourceAndNotifiesUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoP1409-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: deviceID)

        let s1 = UUID()
        let s2 = UUID()
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: s1, seconds: 1, wallClock: Date().addingTimeInterval(-120))
        _ = try await stagePCMChunk(in: archive, root: root, sessionID: s2, seconds: 1, wallClock: Date().addingTimeInterval(-60))

        let lib = archive.libraryInstanceID.uuidString.lowercased()
        let src1 = "\(lib)/\(s1.uuidString.lowercased())"
        let src2 = "\(lib)/\(s2.uuidString.lowercased())"
        let span2 = UUID().uuidString.lowercased()
        let rec2 = Date().addingTimeInterval(-60).timeIntervalSince1970

        let client = try makeStubClient { req, _ in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/v1/transcription/status") {
                return (200, ["Content-Type": "application/json"], Data("{\"settings\":{\"enabled\":true,\"paused\":false,\"vad_threshold\":0.45,\"speaker_lock_threshold\":0.56,\"speaker_lock_margin\":0.08,\"window_max_seconds\":180,\"window_flush_silence_seconds\":12,\"language_hint\":\"auto\",\"custom_hotwords\":[],\"audio_retention_days\":30,\"audio_max_gb\":10.0,\"auto_enroll_from_confirm\":true},\"queue\":{\"pending\":0,\"processing\":0,\"done\":2,\"silent\":0,\"failed\":0},\"storage\":{\"chunk_count\":2,\"total_bytes\":2000,\"total_mb\":0.01},\"voiceprint_count\":0}".utf8))
            }
            if path.hasSuffix("/v1/sources") {
                let body: [String: Any] = [
                    "revision": 2,
                    "items": [
                        ["id": src1, "revision": "1:2:aaa:0", "text_sha256": "aaa", "total_characters": 5, "preview": "A", "recorded_at": rec2 - 60],
                        ["id": src2, "revision": "1:2:bbb:0", "text_sha256": "bbb", "total_characters": 8, "preview": "B", "recorded_at": rec2],
                    ],
                ]
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body))
            }
            if path.hasSuffix("/v1/source") {
                let query = req.url?.query ?? ""
                if query.contains(s1.uuidString.lowercased()) {
                    return (409, ["Content-Type": "application/json"], Data("{\"error\":{\"code\":\"revision_conflict\",\"message\":\"Updated mid-sync\"}}".utf8))
                }
                let body: [String: Any] = [
                    "source_id": src2, "source_revision": "1:2:bbb:0", "text_sha256": "bbb",
                    "offset": 0, "end": 8, "total_characters": 8, "truncated": false, "text": "[我] 第二段成功",
                    "spans": [[
                        "id": span2, "recorded_at": rec2, "end_at": rec2 + 0.8, "text": "[我] 第二段成功",
                        "speaker": "我", "is_owner": true, "timezone_offset": 28_800,
                        "citation_url": "momoagent://source/\(s2.uuidString.lowercased())/\(span2)?version=2&generation=1",
                    ]],
                ]
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body))
            }
            return (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }

        var uiNotified = 0
        let uploader = AudioUploadCoordinator(
            archive: archive,
            deviceID: deviceID,
            dataClientProvider: { client },
            onTranscriptsUpdated: { uiNotified += 1 }
        )
        await uploader.syncRemoteTranscriptsFromMac(force: false)

        let snap2 = try await archive.transcriptSnapshot(sessionID: s2)
        XCTAssertEqual(snap2.document.spans.first?.text, "第二段成功", "Source 2 must still sync despite Source 1 returning HTTP 409!")
        XCTAssertEqual(uiNotified, 1, "onTranscriptsUpdated must still fire when earlier/later sources synced!")
    }
}
