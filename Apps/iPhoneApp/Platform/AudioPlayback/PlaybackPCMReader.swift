import AVFoundation
import Accelerate
import MoMoArchive

/// Queue/actor-confined decoder. At most 8,192 decoded frames are resident at once.
final class PlaybackPCMReader {
    private let file: AVAudioFile
    private let start: AVAudioFramePosition
    private let end: AVAudioFramePosition
    let duration: Double
    var coversEntireFile: Bool { start == 0 && end == file.length }

    init(part: AudioPlaybackPart) throws {
        let manifest = part.lease.manifest
        file = try AVAudioFile(forReading: part.lease.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == manifest.sampleRate,
              Int(file.processingFormat.channelCount) == manifest.channels,
              file.length == manifest.decodedFrameCount, manifest.frames.contains(part.frames) else {
            throw PlaybackError.unavailable
        }
        // Round inward: the clipped citation never includes a sample outside its source range.
        let lower = Double(part.frames.start - manifest.frames.start) / manifest.timebaseHz * manifest.sampleRate
        let upper = Double(part.frames.end - manifest.frames.start) / manifest.timebaseHz * manifest.sampleRate
        let remaining = file.length - manifest.primingFrames - manifest.paddingFrames
        guard lower.isFinite, upper.isFinite, lower >= 0, upper <= Double(remaining) + 1e-7 else {
            throw PlaybackError.unavailable
        }
        start = manifest.primingFrames + Int64((lower - 1e-7).rounded(.up))
        end = manifest.primingFrames + Int64((upper + 1e-7).rounded(.down))
        guard start >= 0, end > start, end <= file.length - manifest.paddingFrames else { throw PlaybackError.unavailable }
        duration = Double(end - start) / manifest.sampleRate
    }

    func writeClip(to url: URL, check: () throws -> Void) throws {
        let output = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try read(check: check) { buffer, _ in try output.write(from: buffer) }
    }

    func envelope(binCount: Int) throws -> [Float] {
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        let total = end - start
        try read(check: { try Task.checkCancellation() }) { buffer, offset in
            guard let channels = buffer.floatChannelData else { throw PlaybackError.unavailable }
            let channelCount = Int(buffer.format.channelCount)
            var frame = 0
            while frame < Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int((offset + Int64(frame)) * Int64(binCount) / total))
                let boundary = (Int64(bin + 1) * total + Int64(binCount) - 1) / Int64(binCount)
                let length = min(Int(buffer.frameLength) - frame, Int(boundary - offset) - frame)
                for channel in 0..<channelCount {
                    var squares: Float = 0
                    vDSP_svesq(channels[channel].advanced(by: frame), 1, &squares, vDSP_Length(length))
                    guard squares.isFinite else { throw PlaybackError.unavailable }
                    sums[bin] += Double(squares)
                    counts[bin] += length
                }
                frame += length
            }
        }
        return sums.indices.map { counts[$0] > 0 ? Float(sqrt(sums[$0] / Double(counts[$0]))) : 0 }
    }

    private func read(check: () throws -> Void, consume: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw PlaybackError.unavailable
        }
        file.framePosition = start
        while file.framePosition < end {
            try check()
            let offset = file.framePosition - start
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, end - file.framePosition)))
            guard buffer.frameLength > 0 else { throw PlaybackError.unavailable }
            try consume(buffer, offset)
        }
    }
}
