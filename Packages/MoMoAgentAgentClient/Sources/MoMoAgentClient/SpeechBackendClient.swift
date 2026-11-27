import CryptoKit
import Foundation

// MARK: - Audio Chunk Ingestion & Streaming DTOs

public struct AudioChunkUploadMeta: Codable, Sendable {
    public let chunkId: String
    public let libraryId: String
    public let sessionId: String
    public let deviceId: String
    public let chunkSeq: Int
    public let recordedAt: Double
    public let durationSec: Double
    public let timezoneOffset: Int?
    public let sourceKind: String
    public let codec: String
    public let sampleRate: Int
    public let sha256: String

    public init(
        chunkId: String,
        libraryId: UUID,
        sessionId: UUID,
        deviceId: UUID,
        chunkSeq: Int,
        recordedAt: Date,
        durationSec: Double,
        timezoneOffset: Int? = TimeZone.current.secondsFromGMT(),
        sourceKind: String = "watch",
        codec: String = "aac",
        sampleRate: Int = 16_000,
        sha256: String
    ) {
        self.chunkId = chunkId
        self.libraryId = libraryId.uuidString.lowercased()
        self.sessionId = sessionId.uuidString.lowercased()
        self.deviceId = deviceId.uuidString.lowercased()
        self.chunkSeq = chunkSeq
        self.recordedAt = recordedAt.timeIntervalSince1970
        self.durationSec = durationSec
        self.timezoneOffset = timezoneOffset
        self.sourceKind = sourceKind
        self.codec = codec
        self.sampleRate = sampleRate
        self.sha256 = sha256.lowercased()
    }
}

public struct AudioChunkUploadReceipt: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let deduplicated: Bool
    public let chunkId: String
    public let sourceId: String
    public let sha256: String
    public let transcriptionStatus: String
}

public struct AudioChunkBatchItemResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let deduplicated: Bool?
    public let chunkId: String
    public let sourceId: String?
    public let sha256: String?
    public let transcriptionStatus: String?
    public let status: Int?
    public let error: String?
}

public struct AudioChunkBatchUploadResponse: Codable, Sendable, Equatable {
    public let results: [AudioChunkBatchItemResult]
}

public struct AudioChunkStatusEntry: Codable, Sendable, Equatable {
    public let uploaded: Bool
    public let sha256: String?
    public let vadStatus: String?
    public let transcriptionStatus: String?
    public let speechSeconds: Double?
    public let error: String?
}

public struct AudioChunkBatchStatusResponse: Codable, Sendable {
    public let statuses: [String: AudioChunkStatusEntry]
}

public struct SourceAudioChunkItem: Codable, Sendable, Identifiable, Equatable {
    public let chunkId: String
    public let chunkSeq: Int
    public let recordedAt: Double
    public let durationSec: Double
    public let endAt: Double
    public let codec: String
    public let byteSize: Int
    public let exists: Bool
    public let path: String?
    public let vadStatus: String
    public let transcriptionStatus: String

    public var id: String { chunkId }
}

public struct SourceAudioChunksResponse: Codable, Sendable {
    public let sourceId: String
    public let chunks: [SourceAudioChunkItem]
}

// MARK: - Mac Speech Settings & Transcription Status DTOs

public struct MacSpeechSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var paused: Bool
    public var vadThreshold: Double
    public var speakerLockThreshold: Double
    public var speakerLockMargin: Double
    public var windowMaxSeconds: Int
    public var windowFlushSilenceSeconds: Int
    public var languageHint: String
    public var customHotwords: [String]
    public var audioRetentionDays: Int
    public var audioMaxGb: Double
    public var autoEnrollFromConfirm: Bool

    public init(
        enabled: Bool = true,
        paused: Bool = false,
        vadThreshold: Double = 0.45,
        speakerLockThreshold: Double = 0.56,
        speakerLockMargin: Double = 0.08,
        windowMaxSeconds: Int = 180,
        windowFlushSilenceSeconds: Int = 12,
        languageHint: String = "auto",
        customHotwords: [String] = [],
        audioRetentionDays: Int = 30,
        audioMaxGb: Double = 10.0,
        autoEnrollFromConfirm: Bool = true
    ) {
        self.enabled = enabled
        self.paused = paused
        self.vadThreshold = vadThreshold
        self.speakerLockThreshold = speakerLockThreshold
        self.speakerLockMargin = speakerLockMargin
        self.windowMaxSeconds = windowMaxSeconds
        self.windowFlushSilenceSeconds = windowFlushSilenceSeconds
        self.languageHint = languageHint
        self.customHotwords = customHotwords
        self.audioRetentionDays = audioRetentionDays
        self.audioMaxGb = audioMaxGb
        self.autoEnrollFromConfirm = autoEnrollFromConfirm
    }
}

public struct MacTranscriptionStatus: Codable, Sendable, Equatable {
    public struct Queue: Codable, Sendable, Equatable {
        public let pending: Int
        public let processing: Int
        public let done: Int
        public let silent: Int
        public let failed: Int
    }
    public struct Storage: Codable, Sendable, Equatable {
        public let chunkCount: Int
        public let totalBytes: Int64
        public let totalMb: Double
    }
    public struct EngineHealth: Codable, Sendable, Equatable {
        public let reachable: Bool?
        public let sileroAvailable: Bool?
        public let mossAvailable: Bool?
        public let redimnetAvailable: Bool?
        public let mossLoaded: Bool?
        public let redimnetLoaded: Bool?
        public let thermalState: String?
        public let error: String?
    }
    public let settings: MacSpeechSettings
    public let queue: Queue
    public let storage: Storage
    public let engine: EngineHealth?
    public let voiceprintCount: Int
}

public struct DictateResponse: Codable, Sendable, Equatable {
    public let text: String
    public let durationSec: Double
    public let elapsedSec: Double
}

// MARK: - Voiceprint Roster & Locking DTOs

public struct VoiceprintSample: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceKind: String
    public let sourceDevice: String
    public let cleanSeconds: Double
    public let snrDb: Double
    public let hasClip: Bool
    public let originSourceId: String?
    public let originSpanId: String?
    public let createdAt: Double
}

public struct VoiceprintProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isOwner: Bool
    public let aliases: [String]
    public let memoryFile: String?
    public let notes: String
    public let sampleCount: Int
    public let totalCleanSeconds: Double
    public let rejectionCount: Int
    public let createdAt: Double
    public let updatedAt: Double
    public let samples: [VoiceprintSample]
}

public struct VoiceprintProfilesResponse: Codable, Sendable {
    public let profiles: [VoiceprintProfile]
}

public struct VoiceprintRematchSummary: Codable, Sendable, Equatable {
    public let scannedClusters: Int
    public let updatedClusters: Int
    public let updatedSpans: Int
    public let touchedSources: [String]
    public let elapsedMs: Double
}

public struct VoiceprintSampleEnrollResponse: Codable, Sendable {
    public struct Quality: Codable, Sendable {
        public let cleanSeconds: Double?
        public let snrDb: Double?
        public let rmsDb: Double?
        public let bucketFrames: Int?
        public let latencyMs: Double?
    }
    public let quality: Quality
    public let rematch: VoiceprintRematchSummary
    public let profile: VoiceprintProfile
}

public struct VoiceprintBindResponse: Codable, Sendable {
    public let success: Bool
    public let sourceId: String
    public let profileId: String?
    public let targetName: String
    public let isOwner: Bool
    public let enrolledVoiceprint: Bool
    public let enrolledSamples: Int
    public let updatedSpanCount: Int
    public let rematch: VoiceprintRematchSummary?
}

public struct VoiceprintRejectResponse: Codable, Sendable {
    public let success: Bool
    public let profileId: String?
    public let speaker: String?
    public let rejectedVectors: Int
    public let affectedSpans: Int
}

// MARK: - AgentClient Speech & Voiceprint Methods

extension AgentClient {
    private static func speechDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func speechEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = .sortedKeys
        return e
    }

    /// Uploads a single 60s AAC/WAV chunk to Mac backend over direct HTTPS (bypassing WebRTC 32 KB limit).
    /// Sets `Idempotency-Key` because ingestion is strictly idempotent by `(chunk_id, sha256)`, allowing
    /// `EmbeddedTailnetTransport` to transparently retry cold SOCKS5 `-1000` (`badURL`) hiccups.
    public func uploadAudioChunk(
        meta: AudioChunkUploadMeta,
        audioData: Data,
        timeout: TimeInterval = 45
    ) async throws -> AudioChunkUploadReceipt {
        let metaBytes = try Self.speechEncoder().encode(meta)
        let metaB64 = metaBytes.base64EncodedString()
        let isWav = ["wav", "pcm", "pcmint16", "pcmfloat32"].contains(meta.codec.lowercased())
        let contentType = isWav ? "audio/wav" : "audio/mp4"
        let idempotencyKey = "chunk-\(meta.chunkId.lowercased())-\(meta.sha256.prefix(16))"
        let data = try await rawRequest(
            path: ["v1", "audio", "chunks"],
            method: "POST",
            body: audioData,
            contentType: contentType,
            extraHeaders: [
                "X-MoMo-Chunk-Meta": metaB64,
                "Idempotency-Key": idempotencyKey
            ],
            timeout: timeout,
            bypassDataChannel: true
        )
        return try Self.speechDecoder().decode(AudioChunkUploadReceipt.self, from: data)
    }

    /// Uploads a batch of audio chunks in one binary-framed HTTP request (`4-byte BE manifest len + JSON + raw bytes`).
    /// Eliminates per-chunk RTT and per-chunk SQLite commit overhead on Tailscale/LAN links.
    public func uploadAudioChunksBatch(
        items: [(meta: AudioChunkUploadMeta, audioData: Data)],
        timeout: TimeInterval = 60
    ) async throws -> AudioChunkBatchUploadResponse {
        guard !items.isEmpty else { return AudioChunkBatchUploadResponse(results: []) }
        struct BatchEntry: Encodable {
            let chunkId: String
            let libraryId: String
            let sessionId: String
            let deviceId: String
            let chunkSeq: Int
            let recordedAt: Double
            let durationSec: Double
            let timezoneOffset: Int?
            let sourceKind: String
            let codec: String
            let sampleRate: Int
            let sha256: String
            let byteSize: Int
        }
        struct BatchManifest: Encodable {
            let chunks: [BatchEntry]
        }

        let entries = items.map { pair in
            BatchEntry(
                chunkId: pair.meta.chunkId,
                libraryId: pair.meta.libraryId,
                sessionId: pair.meta.sessionId,
                deviceId: pair.meta.deviceId,
                chunkSeq: pair.meta.chunkSeq,
                recordedAt: pair.meta.recordedAt,
                durationSec: pair.meta.durationSec,
                timezoneOffset: pair.meta.timezoneOffset,
                sourceKind: pair.meta.sourceKind,
                codec: pair.meta.codec,
                sampleRate: pair.meta.sampleRate,
                sha256: pair.meta.sha256,
                byteSize: pair.audioData.count
            )
        }
        let manifestData = try Self.speechEncoder().encode(BatchManifest(chunks: entries))
        let totalAudioBytes = items.reduce(0) { $0 + $1.audioData.count }
        var body = Data(capacity: 4 + manifestData.count + totalAudioBytes)
        var headerLenBE = UInt32(manifestData.count).bigEndian
        withUnsafeBytes(of: &headerLenBE) { body.append(contentsOf: $0) }
        body.append(manifestData)
        for pair in items {
            body.append(pair.audioData)
        }
        let batchDigest = SHA256.hash(data: manifestData).prefix(12).map { String(format: "%02x", $0) }.joined()
        let data = try await rawRequest(
            path: ["v1", "audio", "chunks", "batch"],
            method: "POST",
            body: body,
            contentType: "application/octet-stream",
            extraHeaders: ["Idempotency-Key": "batch-\(batchDigest)"],
            timeout: timeout,
            bypassDataChannel: true
        )
        return try Self.speechDecoder().decode(AudioChunkBatchUploadResponse.self, from: data)
    }

    public func audioChunkBatchStatus(chunkIDs: [String]) async throws -> AudioChunkBatchStatusResponse {
        struct Payload: Encodable { let chunkIds: [String] }
        let body = try Self.speechEncoder().encode(Payload(chunkIds: chunkIDs))
        let data = try await rawRequest(
            path: ["v1", "audio", "chunks", "batch-status"],
            method: "POST",
            body: body,
            extraHeaders: ["Idempotency-Key": "batch-status-\(UUID().uuidString.lowercased())"],
            timeout: 20
        )
        // Decode outer `statuses` dictionary preserving raw chunk_id keys (do not snake-case-convert UUID/ID keys)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawStatuses = root["statuses"] as? [String: Any] else {
            return AudioChunkBatchStatusResponse(statuses: [:])
        }
        let entryDecoder = Self.speechDecoder()
        var decoded: [String: AudioChunkStatusEntry] = [:]
        decoded.reserveCapacity(rawStatuses.count)
        for (key, value) in rawStatuses {
            if let entryData = try? JSONSerialization.data(withJSONObject: value),
               let entry = try? entryDecoder.decode(AudioChunkStatusEntry.self, from: entryData) {
                decoded[key] = entry
            }
        }
        return AudioChunkBatchStatusResponse(statuses: decoded)
    }

    public func sourceAudioChunks(sourceID: String) async throws -> SourceAudioChunksResponse {
        let data = try await rawRequest(
            path: ["v1", "audio", "chunks"],
            method: "GET",
            query: [URLQueryItem(name: "source_id", value: sourceID)]
        )
        return try Self.speechDecoder().decode(SourceAudioChunksResponse.self, from: data)
    }

    public func audioStreamURLRequest(chunkID: String? = nil, sourceID: String? = nil, atTimestamp: Double? = nil) throws -> URLRequest {
        var query: [URLQueryItem] = []
        if let chunkID { query.append(URLQueryItem(name: "chunk_id", value: chunkID)) }
        if let sourceID { query.append(URLQueryItem(name: "source_id", value: sourceID)) }
        if let atTimestamp { query.append(URLQueryItem(name: "at", value: String(format: "%.3f", atTimestamp))) }
        return try authorizedURLRequest(path: ["v1", "audio", "stream"], query: query)
    }

    /// Downloads an uploaded audio chunk from Mac's `GET /v1/audio/stream?chunk_id=...` over Tailscale/Relay HTTPS
    /// (bypassing WebRTC 32 KB limit) for on-demand playback after local iPhone audio reclaim.
    public func fetchAudioChunkStream(chunkID: String, timeout: TimeInterval = 30) async throws -> Data {
        try await rawRequest(
            path: ["v1", "audio", "stream"],
            method: "GET",
            query: [URLQueryItem(name: "chunk_id", value: chunkID.lowercased())],
            timeout: timeout,
            bypassDataChannel: true
        )
    }

    public func transcriptionStatus() async throws -> MacTranscriptionStatus {
        let data = try await rawRequest(path: ["v1", "transcription", "status"], method: "GET", timeout: 15)
        return try Self.speechDecoder().decode(MacTranscriptionStatus.self, from: data)
    }

    public func requestRetranscribe(sourceID: String) async throws {
        struct Payload: Encodable { let sourceId: String }
        let body = try Self.speechEncoder().encode(Payload(sourceId: sourceID))
        _ = try await rawRequest(
            path: ["v1", "transcription", "retranscribe"],
            method: "POST",
            body: body,
            extraHeaders: ["Idempotency-Key": "retranscribe-\(sourceID.lowercased())"]
        )
    }

    public func speechSettings() async throws -> MacSpeechSettings {
        let data = try await rawRequest(path: ["v1", "speech", "settings"], method: "GET")
        return try Self.speechDecoder().decode(MacSpeechSettings.self, from: data)
    }

    public func updateSpeechSettings(_ settings: MacSpeechSettings) async throws -> MacSpeechSettings {
        let body = try Self.speechEncoder().encode(settings)
        let data = try await rawRequest(path: ["v1", "speech", "settings"], method: "PATCH", body: body)
        return try Self.speechDecoder().decode(MacSpeechSettings.self, from: data)
    }

    public func dictateAudio(_ audioData: Data, filename: String = "dictate.m4a") async throws -> DictateResponse {
        let contentType = filename.lowercased().hasSuffix(".wav") ? "audio/wav" : "audio/mp4"
        let digest = SHA256.hash(data: audioData).prefix(12).map { String(format: "%02x", $0) }.joined()
        let data = try await rawRequest(
            path: ["v1", "speech", "dictate"],
            method: "POST",
            body: audioData,
            contentType: contentType,
            extraHeaders: [
                "X-MoMo-Filename": filename,
                "Idempotency-Key": "dictate-\(digest)"
            ],
            timeout: 60,
            bypassDataChannel: true
        )
        return try Self.speechDecoder().decode(DictateResponse.self, from: data)
    }

    // MARK: - Voiceprints API

    public func voiceprintProfiles() async throws -> [VoiceprintProfile] {
        let data = try await rawRequest(path: ["v1", "voiceprints", "profiles"], method: "GET")
        return try Self.speechDecoder().decode(VoiceprintProfilesResponse.self, from: data).profiles
    }

    public func createVoiceprintProfile(
        name: String,
        isOwner: Bool = false,
        aliases: [String] = [],
        memoryFile: String? = nil,
        notes: String = ""
    ) async throws -> VoiceprintProfile {
        struct Payload: Encodable {
            let name: String
            let isOwner: Bool
            let aliases: [String]
            let memoryFile: String?
            let notes: String
        }
        let body = try Self.speechEncoder().encode(
            Payload(name: name, isOwner: isOwner, aliases: aliases, memoryFile: memoryFile, notes: notes)
        )
        let data = try await rawRequest(path: ["v1", "voiceprints", "profiles"], method: "POST", body: body)
        return try Self.speechDecoder().decode(VoiceprintProfile.self, from: data)
    }

    public func updateVoiceprintProfile(
        id: String,
        name: String,
        isOwner: Bool,
        aliases: [String],
        memoryFile: String? = nil,
        notes: String = ""
    ) async throws -> VoiceprintProfile {
        struct Payload: Encodable {
            let name: String
            let isOwner: Bool
            let aliases: [String]
            let memoryFile: String?
            let notes: String
        }
        let body = try Self.speechEncoder().encode(
            Payload(name: name, isOwner: isOwner, aliases: aliases, memoryFile: memoryFile, notes: notes)
        )
        let data = try await rawRequest(path: ["v1", "voiceprints", "profiles", id], method: "PATCH", body: body)
        return try Self.speechDecoder().decode(VoiceprintProfile.self, from: data)
    }

    public func deleteVoiceprintProfile(id: String) async throws {
        _ = try await rawRequest(path: ["v1", "voiceprints", "profiles", id], method: "DELETE")
    }

    public func enrollVoiceprintSample(
        profileID: String,
        audioData: Data,
        filename: String = "sample.m4a",
        sourceDevice: String = "iphone"
    ) async throws -> VoiceprintSampleEnrollResponse {
        let contentType = filename.lowercased().hasSuffix(".wav") ? "audio/wav" : "audio/mp4"
        let data = try await rawRequest(
            path: ["v1", "voiceprints", "profiles", profileID, "samples"],
            method: "POST",
            body: audioData,
            contentType: contentType,
            extraHeaders: [
                "X-MoMo-Filename": filename,
                "X-MoMo-Device-Kind": sourceDevice
            ],
            timeout: 90,
            bypassDataChannel: true
        )
        return try Self.speechDecoder().decode(VoiceprintSampleEnrollResponse.self, from: data)
    }

    public func deleteVoiceprintSample(profileID: String, sampleID: String) async throws {
        _ = try await rawRequest(
            path: ["v1", "voiceprints", "profiles", profileID, "samples", sampleID],
            method: "DELETE"
        )
    }

    public func voiceprintSampleAudioRequest(profileID: String, sampleID: String) throws -> URLRequest {
        try authorizedURLRequest(path: ["v1", "voiceprints", "profiles", profileID, "samples", sampleID, "audio"])
    }

    public func fetchVoiceprintSampleAudio(profileID: String, sampleID: String) async throws -> Data {
        try await rawRequest(
            path: ["v1", "voiceprints", "profiles", profileID, "samples", sampleID, "audio"],
            method: "GET",
            timeout: 30,
            bypassDataChannel: true
        )
    }

    public func bindTranscriptSpeaker(
        sourceID: String,
        spanIDs: [String]? = nil,
        clusterKey: String? = nil,
        profileID: String? = nil,
        targetName: String? = nil,
        isOwner: Bool = false,
        enrollVoiceprint: Bool = false,
        rematchHistory: Bool = true,
        scope: String = "cluster"
    ) async throws -> VoiceprintBindResponse {
        struct Payload: Encodable {
            let sourceId: String
            let spanIds: [String]?
            let clusterKey: String?
            let profileId: String?
            let targetName: String?
            let isOwner: Bool
            let enrollVoiceprint: Bool
            let rematchHistory: Bool
            let scope: String
        }
        let body = try Self.speechEncoder().encode(
            Payload(
                sourceId: sourceID,
                spanIds: spanIDs,
                clusterKey: clusterKey,
                profileId: profileID,
                targetName: targetName,
                isOwner: isOwner,
                enrollVoiceprint: enrollVoiceprint,
                rematchHistory: rematchHistory,
                scope: scope
            )
        )
        let data = try await rawRequest(path: ["v1", "voiceprints", "bind-transcript"], method: "POST", body: body)
        return try Self.speechDecoder().decode(VoiceprintBindResponse.self, from: data)
    }

    public func rejectSpeakerMatch(
        sourceID: String,
        profileID: String? = nil,
        speakerName: String? = nil,
        spanIDs: [String]? = nil,
        clusterKey: String? = nil
    ) async throws -> VoiceprintRejectResponse {
        struct Payload: Encodable {
            let sourceId: String
            let profileId: String?
            let speakerName: String?
            let spanIds: [String]?
            let clusterKey: String?
        }
        let body = try Self.speechEncoder().encode(
            Payload(
                sourceId: sourceID,
                profileId: profileID,
                speakerName: speakerName,
                spanIds: spanIDs,
                clusterKey: clusterKey
            )
        )
        let data = try await rawRequest(path: ["v1", "voiceprints", "reject"], method: "POST", body: body)
        return try Self.speechDecoder().decode(VoiceprintRejectResponse.self, from: data)
    }

    public func rematchVoiceprints(profileIDs: [String]? = nil) async throws -> VoiceprintRematchSummary {
        struct Payload: Encodable { let profileIds: [String]? }
        let body = try Self.speechEncoder().encode(Payload(profileIds: profileIDs))
        let data = try await rawRequest(
            path: ["v1", "voiceprints", "rematch"],
            method: "POST",
            body: body,
            extraHeaders: ["Idempotency-Key": "rematch-\(UUID().uuidString.lowercased())"]
        )
        return try Self.speechDecoder().decode(VoiceprintRematchSummary.self, from: data)
    }
}
