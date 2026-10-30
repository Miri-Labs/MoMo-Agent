import Foundation

public enum SourceKind: String, Codable, Sendable { case watch, fixture, macTest = "mac_test" }
public enum RepresentationKind: String, Codable, Sendable { case full, priority, preview }
public enum AudioCodec: String, Codable, Sendable { case aac, pcmInt16, pcmFloat32 }

public struct ChunkManifest: Codable, Equatable, Sendable {
    public let manifestVersion: Int
    public let sessionID: UUID
    public let epochID: UUID
    public let chunkID: UUID
    public let sourceDeviceID: UUID
    public let sourceBuild: String
    public let sequence: Int64
    public let frames: FrameRange
    public let timebaseHz: Double
    public let wallClockAnchor: Date
    public let timezoneOffset: Int
    public let codec: AudioCodec
    public let sampleRate: Double
    public let channels: Int
    public let decodedFrameCount: Int64
    public let primingFrames: Int64
    public let paddingFrames: Int64
    public let byteCount: Int64
    public let audioSHA256: String
    public let sealedAt: Date
    public let representation: RepresentationKind
    public let sourceRanges: [FrameRange]
    public let sourceKind: SourceKind

    public init(
        sessionID: UUID, epochID: UUID, chunkID: UUID = UUID(), sourceDeviceID: UUID,
        sourceBuild: String, sequence: Int64, frames: FrameRange, timebaseHz: Double,
        wallClockAnchor: Date, timezoneOffset: Int, codec: AudioCodec, sampleRate: Double,
        channels: Int, decodedFrameCount: Int64, primingFrames: Int64 = 0,
        paddingFrames: Int64 = 0, byteCount: Int64, audioSHA256: String,
        sealedAt: Date = Date(), representation: RepresentationKind = .full,
        sourceRanges: [FrameRange]? = nil, sourceKind: SourceKind = .watch
    ) throws {
        manifestVersion = 1
        self.sessionID = sessionID; self.epochID = epochID; self.chunkID = chunkID
        self.sourceDeviceID = sourceDeviceID; self.sourceBuild = sourceBuild
        self.sequence = sequence; self.frames = frames; self.timebaseHz = timebaseHz
        self.wallClockAnchor = wallClockAnchor; self.timezoneOffset = timezoneOffset
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.decodedFrameCount = decodedFrameCount; self.primingFrames = primingFrames
        self.paddingFrames = paddingFrames; self.byteCount = byteCount
        self.audioSHA256 = audioSHA256; self.sealedAt = sealedAt
        self.representation = representation; self.sourceRanges = sourceRanges ?? [frames]
        self.sourceKind = sourceKind
        try validate()
    }

    public func validate() throws {
        guard manifestVersion == 1 else { throw ContractError.unsupportedVersion(manifestVersion) }
        guard !sourceBuild.isEmpty, sourceBuild.utf8.count <= 256 else {
            throw ContractError.invalidField("source_build")
        }
        guard sequence >= 0, timebaseHz.isFinite, timebaseHz > 0,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels), (-50_400...50_400).contains(timezoneOffset),
              byteCount > 0, decodedFrameCount > 0,
              primingFrames >= 0, paddingFrames >= 0,
              primingFrames <= decodedFrameCount,
              paddingFrames <= decodedFrameCount - primingFrames,
              wallClockAnchor.timeIntervalSince1970.isFinite,
              sealedAt.timeIntervalSince1970.isFinite else {
            throw ContractError.invalidField("audio_format_or_range")
        }
        guard ContentHash.isValid(audioSHA256) else { throw ContractError.invalidField("audio_sha256") }
        guard !sourceRanges.isEmpty, sourceRanges.count <= 32 else {
            throw ContractError.invalidField("source_ranges")
        }
        if representation == .full, sourceRanges != [frames] {
            throw ContractError.invalidField("full_source_ranges")
        }
    }
}

/// Carries the original JSON bytes; receipt identity never depends on re-encoding a received manifest.
public struct ManifestEnvelope: Codable, Equatable, Sendable {
    public static let maximumManifestBytes = 16 * 1024
    public let protocolVersion: Int
    public let manifestData: Data
    public let manifestSHA256: String
    public let manifest: ChunkManifest

    public init(manifest: ChunkManifest) throws {
        try manifest.validate()
        let data = try WireJSON.encode(manifest)
        try self.init(manifestData: data, manifestSHA256: ContentHash.sha256(data))
    }

    public init(manifestData: Data, manifestSHA256: String, protocolVersion: Int = 1) throws {
        guard protocolVersion == 1 else { throw ContractError.unsupportedVersion(protocolVersion) }
        guard manifestData.count <= Self.maximumManifestBytes else { throw ContractError.manifestTooLarge }
        guard ContentHash.sha256(manifestData) == manifestSHA256 else { throw ContractError.hashMismatch }
        let manifest = try WireJSON.decode(ChunkManifest.self, from: manifestData)
        try manifest.validate()
        self.protocolVersion = protocolVersion
        self.manifestData = manifestData
        self.manifestSHA256 = manifestSHA256
        self.manifest = manifest
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, manifestData, manifestSHA256 }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(manifestData: values.decode(Data.self, forKey: .manifestData),
                      manifestSHA256: values.decode(String.self, forKey: .manifestSHA256),
                      protocolVersion: values.decode(Int.self, forKey: .protocolVersion))
    }
}
