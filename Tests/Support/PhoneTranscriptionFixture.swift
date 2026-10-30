import AVFoundation
import Foundation
import MoMoContracts
import MoMoRecording

/// Shared by the iOS integration tests and the Mac replay command.
public enum PhoneTranscriptionFixture {
    public static let expectedFragments = ["开放时间早上9点至下午5点"]
    public static let officialWAVSHA256 = "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"

    public static func makeCrossChunk(officialWAV: URL, directory: URL,
                                     wallClockAnchor: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> [URL] {
        guard try ContentHash.sha256(fileAt: officialWAV) == officialWAVSHA256 else {
            throw FixtureError.invalidOfficialAudio
        }
        let pcm = try readPCM(officialWAV)
        var writer = try makeWriter(directory: directory, wallClockAnchor: wallClockAnchor)
        var chunks = try writer.append([Int16](repeating: 0, count: 57 * 16000))
        chunks += try writer.append(pcm)
        chunks += try writer.append([Int16](repeating: 0, count: 2 * 16000))
        if let last = try writer.finish() { chunks.append(last) }
        guard chunks.count == 2 else { throw FixtureError.boundaryNotExercised }
        return chunks.map(\.audioURL)
    }

    public static func makeSilence(directory: URL) throws -> URL {
        var writer = try makeWriter(directory: directory)
        guard try writer.append([Int16](repeating: 0, count: 2 * 16000)).isEmpty,
              let chunk = try writer.finish() else { throw FixtureError.invalidSilence }
        return chunk.audioURL
    }

    /// A repeatable sparse workload, not a natural-conversation accuracy corpus.
    public static func makeSparseHour(officialWAV: URL, directory: URL) throws -> [URL] {
        guard try ContentHash.sha256(fileAt: officialWAV) == officialWAVSHA256 else {
            throw FixtureError.invalidOfficialAudio
        }
        let pcm = try readPCM(officialWAV)
        let silence = [Int16](repeating: 0, count: 60 * 16_000 - pcm.count)
        var writer = try makeWriter(directory: directory)
        var urls: [URL] = []
        for _ in 0..<60 {
            urls += try writer.append(pcm).map(\.audioURL)
            urls += try writer.append(silence).map(\.audioURL)
        }
        if let tail = try writer.finish() { urls.append(tail.audioURL) }
        return urls
    }

    /// Repeated public speech with 750 ms gaps, keeping every minute and the full hour exact.
    /// This measures dense processing throughput, not natural-conversation accuracy.
    public static func makeDenseHour(officialWAV: URL, directory: URL) throws -> [URL] {
        guard try ContentHash.sha256(fileAt: officialWAV) == officialWAVSHA256 else {
            throw FixtureError.invalidOfficialAudio
        }
        let pcm = try readPCM(officialWAV)
        let gap = [Int16](repeating: 0, count: 12_000)
        var writer = try makeWriter(directory: directory)
        var urls: [URL] = []
        for _ in 0..<60 {
            var remaining = 60 * 16_000
            while remaining >= pcm.count + gap.count {
                urls += try writer.append(pcm).map(\.audioURL)
                urls += try writer.append(gap).map(\.audioURL)
                remaining -= pcm.count + gap.count
            }
            urls += try writer.append([Int16](repeating: 0, count: remaining)).map(\.audioURL)
        }
        if let tail = try writer.finish() { urls.append(tail.audioURL) }
        return urls
    }

    /// The text oracle follows the generated audio, independently of VAD window boundaries.
    public static func hourUtteranceCount(officialWAV: URL, dense: Bool) throws -> Int {
        guard try ContentHash.sha256(fileAt: officialWAV) == officialWAVSHA256 else {
            throw FixtureError.invalidOfficialAudio
        }
        let frames = try readPCM(officialWAV).count
        return dense ? 60 * ((60 * 16_000) / (frames + 12_000)) : 60
    }

    private static func makeWriter(directory: URL,
                                   wallClockAnchor: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> PCM16SegmentWriter {
        try PCM16SegmentWriter(directory: directory, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sourceBuild: "phone-transcription-fixture", sourceKind: .fixture,
            wallClockAnchor: wallClockAnchor, timezoneOffset: 28800)
    }

    private static func readPCM(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 3 * 16000, file.length < 20 * 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw FixtureError.invalidOfficialAudio
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData, Int64(buffer.frameLength) == file.length else {
            throw FixtureError.invalidOfficialAudio
        }
        return Array(UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength))).map {
            Int16(max(-32768, min(32767, ($0 * 32767).rounded())))
        }
    }

    private enum FixtureError: Error {
        case invalidOfficialAudio, boundaryNotExercised, invalidSilence
    }
}
