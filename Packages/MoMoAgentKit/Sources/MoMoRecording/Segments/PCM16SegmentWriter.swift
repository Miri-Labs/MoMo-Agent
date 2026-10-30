import Foundation
import MoMoContracts

public struct EncodedChunk: Sendable {
    public let audioURL: URL
    public let envelope: ManifestEnvelope
}

public enum SegmentWriterError: Error, Equatable {
    case invalidFormat, misalignedSamples, alreadyFinished, sequenceOverflow
}

/// A serial, bounded PCM writer for replay and lossless capture validation.
/// AAC encoding is a platform adapter; it uses the same immutable sealing boundary.
public struct PCM16SegmentWriter {
    private let directory: URL
    private let sessionID: UUID
    private let epochID: UUID
    private let sourceDeviceID: UUID
    private let sourceBuild: String
    private let sourceKind: SourceKind
    private let sampleRate: Int
    private let channels: Int
    private let targetFrames: Int
    private let wallClockAnchor: Date
    private let timezoneOffset: Int
    private var samples: [Int16] = []
    private var startFrame: Int64 = 0
    private var sequence: Int64 = 0
    private var finished = false

    public init(directory: URL, sessionID: UUID, epochID: UUID, sourceDeviceID: UUID,
                sourceBuild: String, sourceKind: SourceKind, sampleRate: Int = 16_000,
                channels: Int = 1, targetFrames: Int = 960_000,
                wallClockAnchor: Date, timezoneOffset: Int) throws {
        guard (8_000...192_000).contains(sampleRate), (1...2).contains(channels),
              targetFrames > 0, targetFrames <= sampleRate * 300 else { throw SegmentWriterError.invalidFormat }
        self.directory = directory
        self.sessionID = sessionID
        self.epochID = epochID
        self.sourceDeviceID = sourceDeviceID
        self.sourceBuild = sourceBuild
        self.sourceKind = sourceKind
        self.sampleRate = sampleRate
        self.channels = channels
        self.targetFrames = targetFrames
        self.wallClockAnchor = wallClockAnchor
        self.timezoneOffset = timezoneOffset
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public mutating func append(_ input: [Int16]) throws -> [EncodedChunk] {
        guard !finished else { throw SegmentWriterError.alreadyFinished }
        guard input.count.isMultiple(of: channels) else { throw SegmentWriterError.misalignedSamples }
        var chunks: [EncodedChunk] = []
        var offset = 0
        while offset < input.count {
            let count = min(targetFrames * channels - samples.count, input.count - offset)
            samples.append(contentsOf: input[offset..<(offset + count)])
            offset += count
            if samples.count == targetFrames * channels { chunks.append(try writeChunk()) }
        }
        return chunks
    }

    public mutating func finish() throws -> EncodedChunk? {
        guard !finished else { throw SegmentWriterError.alreadyFinished }
        let chunk = samples.isEmpty ? nil : try writeChunk()
        finished = true
        return chunk
    }

    public var bufferedFrames: Int { samples.count / channels }

    private mutating func writeChunk() throws -> EncodedChunk {
        let frames = Int64(samples.count / channels)
        guard sequence < Int64.max, startFrame <= Int64.max - frames else { throw SegmentWriterError.sequenceOverflow }
        let audio = waveData(samples: samples, sampleRate: sampleRate, channels: channels)
        let chunkID = UUID()
        let url = directory.appendingPathComponent(chunkID.uuidString).appendingPathExtension("wav")
        try audio.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { let original = error; do { try handle.close() } catch { throw error }; throw original }
        let manifest = try ChunkManifest(
            sessionID: sessionID, epochID: epochID, chunkID: chunkID, sourceDeviceID: sourceDeviceID,
            sourceBuild: sourceBuild, sequence: sequence, frames: FrameRange(start: startFrame, count: frames),
            timebaseHz: Double(sampleRate), wallClockAnchor: wallClockAnchor, timezoneOffset: timezoneOffset,
            codec: .pcmInt16, sampleRate: Double(sampleRate), channels: channels, decodedFrameCount: frames,
            byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: sourceKind
        )
        let chunk = EncodedChunk(audioURL: url, envelope: try ManifestEnvelope(manifest: manifest))
        startFrame += frames
        sequence += 1
        samples.removeAll(keepingCapacity: true)
        return chunk
    }

    private func waveData(samples: [Int16], sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 2))
        for sample in samples { append(sample) }
        return data
    }
}
