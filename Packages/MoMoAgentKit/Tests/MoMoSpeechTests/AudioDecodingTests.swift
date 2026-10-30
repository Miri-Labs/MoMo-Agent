import AVFoundation
import Foundation
import Testing
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

@Test func decoderRetainsNativeReadErrorDomainAndCode() throws {
    let directory = decodingOutput()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Decoder fixture cleanup failed: \(error)") }
    }
    let url = directory.appendingPathComponent("invalid.wav")
    let bytes = Data(repeating: 0, count: 3_244)
    try bytes.write(to: url)
    let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "decoder-error",
        sequence: 0, frames: FrameRange(start: 0, count: 1_600), timebaseHz: 16_000, wallClockAnchor: Date(), timezoneOffset: 0,
        codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 1_600,
        byteCount: Int64(bytes.count), audioSHA256: ContentHash.sha256(bytes), sourceKind: .fixture)
    let input = SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: url)
    let reader = try EpochAudioReader(input: SpeechInputSet([input], anchor: 0), attempt: SpeechAttempt())
    do {
        _ = try reader.next()
        Issue.record("The actual decoder must reject an invalid container.")
    } catch let SpeechError.audioRead(domain, code) {
        #expect(!domain.isEmpty)
        #expect(code != 0)
    }
}

@Test func decoderRemovesDeclaredPrimingAndPaddingExactly() throws {
    let directory = decodingOutput()
    var writer = try PCM16SegmentWriter(directory: directory, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
                                        sourceBuild: "trim-test", sourceKind: .fixture, wallClockAnchor: Date(), timezoneOffset: 0)
    let original = (0..<4_000).map { Int16($0) }
    _ = try writer.append(original)
    let tail = try writer.finish()
    let chunk = try #require(tail)
    let input = try decodingInput(chunk.audioURL, codec: .pcmInt16, priming: 256, padding: 512)
    let reader = try EpochAudioReader(input: SpeechInputSet([input], anchor: 0), attempt: SpeechAttempt())
    var samples: [Float] = []
    while let block = try reader.next() { samples += block }
    #expect(samples == original[256..<3_488].map { Float($0) / 32_768 })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
func aacLCChineseAudioUsesRealDecoderAndRecognizer() async throws {
    let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
    let original = try AVAudioFile(forReading: model.appendingPathComponent("test_wavs/zh.wav"),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: AVAudioFrameCount(original.length)))
    try original.read(into: buffer)
    let directory = decodingOutput()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chinese.m4a")
    try encodeAAC(buffer, to: url)
    let input = try decodingInput(url, codec: .aac)
    let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration())
    let batch = try await engine.prepare(inputs: [input], epochClosed: true)
    let window = try #require(batch.windows.first)
    let result = try await engine.transcribe(window: window, inputs: [input])
    #expect(result.text == "开放时间早上9点至下午5点。")
}

private func encodeAAC(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
    let file = try AVAudioFile(forWriting: url,
                               settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

private func decodingOutput() -> URL {
    let root = ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("speech-decoding-" + UUID().uuidString)
}

private func decodingInput(_ url: URL, codec: MoMoContracts.AudioCodec,
                           priming: Int64 = 0, padding: Int64 = 0) throws -> SpeechAudioInput {
    let file = try AVAudioFile(forReading: url)
    let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "decoder-test",
                                     sequence: 0, frames: FrameRange(start: 0, count: file.length - priming - padding),
                                     timebaseHz: file.processingFormat.sampleRate, wallClockAnchor: Date(), timezoneOffset: 0,
                                     codec: codec, sampleRate: file.processingFormat.sampleRate,
                                     channels: Int(file.processingFormat.channelCount), decodedFrameCount: file.length,
                                     primingFrames: priming, paddingFrames: padding, byteCount: Int64(Data(contentsOf: url).count),
                                     audioSHA256: ContentHash.sha256(fileAt: url), sourceKind: .fixture)
    return SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: url)
}
