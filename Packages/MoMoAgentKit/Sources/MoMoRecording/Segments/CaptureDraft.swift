import AVFAudio
import Foundation
import MoMoContracts

/// Written before creating the container. A final frame count is optional until closing starts.
struct CaptureDraft: Codable {
    let version: Int
    let sessionID: UUID
    let epochID: UUID
    let chunkID: UUID
    let sourceDeviceID: UUID
    let sourceBuild: String
    let sourceKind: SourceKind
    let sequence: Int64
    let startFrame: Int64
    let maximumFrames: Int64
    let sampleRate: Double
    let wallClockAnchor: Date
    let timezoneOffset: Int
    var closingFrameCount: Int64?

    func envelope(audioURL: URL, verifyFullDecode: Bool = true) throws -> ManifestEnvelope {
        guard version == 1, maximumFrames > 0, maximumFrames <= 4_800_000,
              sampleRate == 16_000 else { throw AACWriterError.invalidFormat }
        let reader = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard reader.processingFormat.sampleRate == sampleRate, reader.processingFormat.channelCount == 1 else {
            throw AACWriterError.invalidFormat
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8_192) else {
            throw AACWriterError.allocationFailed
        }
        var frames: Int64 = 0
        if !verifyFullDecode, let closingFrameCount, closingFrameCount > 0, closingFrameCount <= maximumFrames,
           reader.length == closingFrameCount {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(1_024, reader.length)))
            guard buffer.frameLength > 0 else { throw AACWriterError.conversionFailed }
            frames = closingFrameCount
        } else {
            while reader.framePosition < reader.length {
                try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, reader.length - reader.framePosition)))
                guard buffer.frameLength > 0 else { throw AACWriterError.conversionFailed }
                frames += Int64(buffer.frameLength)
                guard frames <= maximumFrames else { throw AACWriterError.invalidFormat }
            }
        }
        guard frames > 0 else { throw AACWriterError.invalidFormat }
        if let closingFrameCount, frames != closingFrameCount {
            throw AACWriterError.decodedFrameMismatch(expected: closingFrameCount, actual: frames)
        }
        guard let bytes = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw AACWriterError.invalidFormat }
        return try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: sessionID, epochID: epochID, chunkID: chunkID, sourceDeviceID: sourceDeviceID,
            sourceBuild: sourceBuild, sequence: sequence, frames: FrameRange(start: startFrame, count: frames),
            timebaseHz: sampleRate, wallClockAnchor: wallClockAnchor, timezoneOffset: timezoneOffset,
            codec: .aac, sampleRate: sampleRate, channels: 1, decodedFrameCount: frames,
            byteCount: Int64(bytes), audioSHA256: ContentHash.sha256(fileAt: audioURL), sourceKind: sourceKind))
    }
}

enum AACSealStep { case beforeContainerClose, afterContainerClose }
