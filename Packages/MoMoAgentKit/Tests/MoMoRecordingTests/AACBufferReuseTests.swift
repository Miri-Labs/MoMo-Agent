import AVFAudio
import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

@available(macOS 15, iOS 18, watchOS 11, *)
@Test(arguments: [8_000.0, 16_000, 44_100, 48_000, 192_000])
func variableAACBuffersPreserveSamplesAcrossChunkBoundaries(inputRate: Double) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoAACBuffers-\(UUID())")
    defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    let writer = try AACSegmentWriter(directory: root, sessionID: UUID(), epochID: UUID(),
        sourceDeviceID: UUID(), sourceBuild: "tests", sourceKind: .fixture, inputSampleRate: inputRate,
        targetSeconds: 0.7, wallClockAnchor: Date(), timezoneOffset: 0)
    // Upsampling can fill the output more than once; short blocks must not replay its old tail.
    let sizes = [1, 8_192, 17, 1_024, 511]
    let inputCount = Int(inputRate * 2.5)
    var offset = 0, block = 0
    var chunks: [EncodedChunk] = []
    while offset < inputCount {
        let end = min(inputCount, offset + sizes[block % sizes.count])
        chunks += try writer.append((offset..<end).map { Float(0.3 * sin(Double($0) * 2 * .pi * 440 / inputRate)) })
        offset = end
        block += 1
    }
    chunks += try writer.finish()
    #expect(writer.totalFrames == 40_000)
    #expect(chunks.map { $0.envelope.manifest.frames.count } == [11_200, 11_200, 11_200, 6_400])
    #expect(chunks.map { $0.envelope.manifest.frames.start } == [0, 11_200, 22_400, 33_600])
    var decoded: [Float] = []
    for chunk in chunks {
        let manifest = chunk.envelope.manifest
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == manifest.audioSHA256)
        let reader = try AVAudioFile(forReading: chunk.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4_096))
        while reader.framePosition < reader.length {
            try reader.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            #expect(buffer.frameLength > 0)
            guard buffer.frameLength > 0 else { break }
            decoded.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }
    #expect(decoded.count == 40_000)
    // Check audio content as well as metadata: stale or missing PCM can still produce a valid m4a.
    let meanSquareError = decoded.enumerated().reduce(0.0) { sum, pair in
        let expected = 0.3 * sin(Double(pair.offset) * 2 * .pi * 440 / 16_000)
        return sum + pow(Double(pair.element) - expected, 2)
    } / Double(max(1, decoded.count))
    #expect(meanSquareError < 0.005)
}
