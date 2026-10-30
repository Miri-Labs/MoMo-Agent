import AVFoundation
import Foundation
import os
import Testing
import MoMoContracts
@testable import MoMoSpeech

struct SequentialSpeechTests {
    @Test(arguments: [16_000, 44_100, 48_000], [false, true])
    func sequentialPCMMatchesFreshReaderAcrossBoundaries(rate: Int, aac: Bool) throws {
        let fixture = try SequenceFixture(rate: rate, aac: aac)
        defer { fixture.remove() }
        let input = try SpeechInputSet(fixture.inputs, anchor: 0)
        let configuration = try SpeechConfiguration(maximumCoreFrames: 16_000)
        let cursor = try SequentialSpeechSamples(input: input, configuration: configuration, attempt: SpeechAttempt())
        let ranges = try [FrameRange(start: 0, count: 16_000), FrameRange(start: 14_000, count: 20_000),
                          FrameRange(start: 32_000, count: 16_000), FrameRange(start: 46_000, count: input.modelFrameCount - 46_000)]
        var evidence: [[String: String]] = []
        for range in ranges {
            let context = try input.sourceRange(range)
            let actual = try cursor.samples(for: range, sourceContext: context, attempt: SpeechAttempt())
            let prefix = fixture.inputs.filter { $0.envelope.manifest.frames.start < context.end }
            let reader = try EpochAudioReader(input: SpeechInputSet(prefix, anchor: 0), attempt: SpeechAttempt())
            var expected: [Float] = []
            while let block = try reader.next() {
                expected += block
                if expected.count >= range.end { break }
            }
            let wanted = Array(expected[Int(range.start)..<Int(range.end)])
            let controlReader = try EpochAudioReader(input: SpeechInputSet(prefix, anchor: 0), attempt: SpeechAttempt())
            var control: [Float] = []
            while let block = try controlReader.next() { control += block; if control.count >= range.end { break } }
            let controlWindow = Array(control[Int(range.start)..<Int(range.end)])
            func hash(_ samples: [Float]) -> String { samples.withUnsafeBufferPointer { ContentHash.sha256(Data(buffer: $0)) } }
            let actualHash = hash(actual), wantedHash = hash(wanted), controlHash = hash(controlWindow)
            evidence.append(["rate": String(rate), "aac": String(aac), "modelStart": String(range.start), "modelEnd": String(range.end),
                "oldInputSourceEnd": String(prefix.last!.envelope.manifest.frames.end), "sequenceSnapshotSourceEnd": String(input.end),
                "sequentialPCMSHA256": actualHash, "freshPCMSHA256": wantedHash, "secondFreshPCMSHA256": controlHash])
            #expect(wantedHash == controlHash, "Fresh-reader reproducibility")
            #expect(actual.count == wanted.count)
            if aac {
                // The unchanged main reader also differs by up to 2.7e-7 on this
                // macOS AAC decoder. Bound rounding well below one PCM16 step.
                let maximumError = zip(actual, wanted).map { abs($0 - $1) }.max() ?? 0
                #expect(maximumError <= 4 * Float.ulpOfOne,
                    "rate=\(rate) aac=\(aac) range=\(range)")
            } else {
                #expect(actualHash == wantedHash, "Exact PCM bit patterns, including padding")
            }
        }
        if let output = ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"] {
            try WireJSON.encode(evidence).write(to: URL(fileURLWithPath: output).appendingPathComponent("sequence-pcm-\(rate)-aac-\(aac).json"))
        }
    }

    @Test(arguments: [false, true])
    func replacementOfContinuedOrNewFileFailsBeforeFurtherSamples(newFile: Bool) throws {
        let fixture = try SequenceFixture(rate: 48_000, aac: false)
        defer { fixture.remove() }
        let input = try SpeechInputSet(fixture.inputs, anchor: 0)
        let cursor = try SequentialSpeechSamples(input: input, configuration: SpeechConfiguration(), attempt: SpeechAttempt())
        let first = try FrameRange(start: 0, count: 4_096)
        _ = try cursor.samples(for: first, sourceContext: input.sourceRange(first), attempt: SpeechAttempt())
        let target = fixture.inputs[newFile ? 1 : 0]
        var data = try Data(contentsOf: target.audioURL)
        data[data.count - 100] ^= 0xff
        try data.write(to: target.audioURL, options: .atomic)
        let next = try FrameRange(start: 4_096, count: 20_000)
        #expect(throws: SpeechError.invalidAudio("audio_identity")) {
            _ = try cursor.samples(for: next, sourceContext: input.sourceRange(next), attempt: SpeechAttempt())
        }
    }

    @Test func gapsAndCancellationNeverReuseAnOldAttempt() throws {
        let fixture = try SequenceFixture(rate: 44_100, aac: false)
        defer { fixture.remove() }
        let input = try SpeechInputSet(fixture.inputs, anchor: 137)
        let cursor = try SequentialSpeechSamples(input: input, configuration: SpeechConfiguration(), attempt: SpeechAttempt())
        for range in try [FrameRange(start: 1_000, count: 3_000), FrameRange(start: 50_000, count: 2_000)] {
            let actual = try cursor.samples(for: range, sourceContext: input.sourceRange(range), attempt: SpeechAttempt())
            let reader = try EpochAudioReader(input: input, attempt: SpeechAttempt())
            var full: [Float] = []
            while let block = try reader.next() { full += block }
            #expect(actual == Array(full[Int(range.start)..<Int(range.end)]))
        }
        let cancelled = SpeechAttempt(); cancelled.cancel()
        let range = try FrameRange(start: 52_000, count: 100)
        #expect(throws: SpeechError.cancelled) {
            try cursor.samples(for: range, sourceContext: input.sourceRange(range), attempt: cancelled)
        }
    }

    @Test(arguments: [44_100, 48_000])
    func changedUnreadTailBeforeSkippedGapIsRejected(rate: Int) throws {
        let fixture = try SequenceFixture(rate: rate, aac: false)
        defer { fixture.remove() }
        let input = try SpeechInputSet(fixture.inputs, anchor: 0)
        let cursor = try SequentialSpeechSamples(input: input, configuration: SpeechConfiguration(), attempt: SpeechAttempt())
        let first = try FrameRange(start: 0, count: 4_096)
        _ = try cursor.samples(for: first, sourceContext: input.sourceRange(first), attempt: SpeechAttempt())
        let url = fixture.inputs[0].audioURL
        let original = try Data(contentsOf: url)
        let offset = original.count - 256
        #expect(original[offset..<(offset + 64)] != Data(repeating: 0, count: 64))
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: Data(repeating: 0, count: 64))
        try file.close()
        let next = try FrameRange(start: 16_000, count: 4_096)
        #expect(try input.sourceRange(next).start == fixture.inputs[0].envelope.manifest.frames.end)
        #expect(throws: SpeechError.invalidAudio("audio_identity")) {
            _ = try cursor.samples(for: next, sourceContext: input.sourceRange(next), attempt: SpeechAttempt())
        }
    }
}

private struct SequenceFixture {
    let directory: URL
    let inputs: [SpeechAudioInput]
    init(rate: Int, aac: Bool, source: [Float]? = nil, chunkSeconds: Int = 1) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-sequence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID(), epoch = UUID(), device = UUID()
        var values: [SpeechAudioInput] = [], start: Int64 = 0
        for index in 0..<4 {
            let count = rate * chunkSeconds + (index == 3 ? 137 : 0)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<count {
                if let source {
                    let sourceIndex = Int(Double(start + Int64(frame)) * 16_000 / Double(rate)) % source.count
                    samples[frame] = source[sourceIndex]
                } else { samples[frame] = Float(sin(Double(start + Int64(frame)) * 0.071) * 0.4) }
            }
            let url = directory.appendingPathComponent("\(index).\(aac ? "m4a" : "wav")")
            let settings: [String: Any] = aac
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: rate == 16_000 ? 24_000 : 64_000]
                : format.settings
            try Self.write(buffer, to: url, settings: settings)
            let decoded = try AVAudioFile(forReading: url)
            let manifest = try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: device,
                sourceBuild: "sequence-equivalence", sequence: Int64(index), frames: FrameRange(start: start, count: decoded.length),
                timebaseHz: Double(rate), wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0,
                codec: aac ? .aac : .pcmFloat32, sampleRate: Double(rate), channels: 1, decodedFrameCount: decoded.length,
                byteCount: Int64(Data(contentsOf: url).count), audioSHA256: ContentHash.sha256(fileAt: url), sourceKind: .fixture)
            values.append(SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: url))
            start += decoded.length
        }
        inputs = values
    }
    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    func remove() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
}


@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct RealSequentialSpeechTests {
    @Test(arguments: [44_100, 48_000])
    func incrementalAACCacheMatchesFreshRecognitionAcrossFiles(rate: Int) async throws {
        let model = try modelDirectory()
        let fixture = try SequenceFixture(rate: rate, aac: true, source: voice(model), chunkSeconds: 2)
        defer { fixture.remove() }
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model),
            configuration: SpeechConfiguration(maximumCoreFrames: 64_000),
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        let end = try #require(fixture.inputs.last).envelope.manifest.frames.end
        let stream = engine.prepareStream(inputs: fixture.inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        let sequence = try engine.makeTranscriptionSequence(inputs: fixture.inputs, anchor: 0)
        do {
            var recognized = 0, cacheHits = 0
            while let page = try await stream.next() {
                for window in page.batch.windows {
                    let cached = try await engine.transcribe(window: window, sequence: sequence)
                    let diagnostic = try #require(observations.withLock { $0.last { $0.operation == .transcribe && $0.windowID == window.id } })
                    if diagnostic.preparedAudioModelFrames > 0 {
                        cacheHits += 1
                        #expect(diagnostic.preparedAudioModelFrames == window.modelContextFrames.count)
                        #expect(diagnostic.convertedModelFrames == 0 && diagnostic.sourceFramesRead == 0)
                    }
                    let fresh = try await engine.transcribe(window: window, inputs: fixture.inputs)
                    #expect(cached == fresh)
                    recognized += 1
                }
                if page.isFinal { break }
            }
            await stream.waitUntilFinished()
            await engine.close(sequence)
            #expect(recognized > 0 && cacheHits > 0)
        } catch {
            stream.cancel(); await stream.waitUntilFinished(); await engine.close(sequence); throw error
        }
    }

    @Test(arguments: [44_100, 48_000])
    func realAACRecognitionMatchesFreshWindows(rate: Int) async throws {
        let model = try modelDirectory()
        let fixture = try SequenceFixture(rate: rate, aac: true, source: voice(model), chunkSeconds: 2)
        defer { fixture.remove() }
        let config = try SpeechConfiguration(maximumCoreFrames: 64_000)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: config)
        let input = try SpeechInputSet(fixture.inputs, anchor: 0)
        let windows = try WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint).windows(
            ranges: [0..<input.modelFrameCount], input: input, availableThrough: input.modelFrameCount, tailClosed: true)
        let sequence = try engine.makeTranscriptionSequence(inputs: fixture.inputs, anchor: 0)
        do {
            var words = 0
            for window in windows {
                let prefix = fixture.inputs.filter { $0.envelope.manifest.frames.start < window.contextFrames.end }
                let old = try await engine.transcribe(window: window, inputs: prefix)
                let new = try await engine.transcribe(window: window, sequence: sequence)
                #expect(new.windowID == old.windowID)
                #expect(new.text == old.text)
                #expect(new.tokens == old.tokens)
                #expect(new.timestamps == old.timestamps)
                #expect(new.rawJSON == old.rawJSON)
                words += new.text.utf8.count
            }
            #expect(words > 0)
            await engine.close(sequence)
        } catch { await engine.close(sequence); throw error }
    }

    @Test func nativeCancellationClosesSequenceAndFreshAttemptStillWorks() async throws {
        let model = try modelDirectory()
        let fixture = try SequenceFixture(rate: 16_000, aac: false, source: voice(model), chunkSeconds: 2)
        defer { fixture.remove() }
        let config = try SpeechConfiguration()
        let cancelled = SpeechAttempt()
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: config) { event in
            if case .nativeDecodeStarted = event { cancelled.cancel() }
        }
        let input = try SpeechInputSet(fixture.inputs, anchor: 0)
        let range = try FrameRange(start: 0, count: input.modelFrameCount)
        let window = try WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint)
            .makeWindow(core: range, context: range, input: input)
        let sequence = try engine.makeTranscriptionSequence(inputs: fixture.inputs, anchor: 0)
        await #expect(throws: SpeechError.cancelled) {
            try await engine.transcribe(window: window, sequence: sequence, attempt: cancelled)
        }
        await #expect(throws: SpeechError.incompatibleWindow) {
            try await engine.transcribe(window: window, sequence: sequence)
        }
        let retry = try engine.makeTranscriptionSequence(inputs: fixture.inputs, anchor: 0)
        do {
            let result = try await engine.transcribe(window: window, sequence: retry)
            #expect(!result.text.isEmpty)
            await engine.close(retry)
        } catch { await engine.close(retry); throw error }
    }

    private func modelDirectory() throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
    }
    private func voice(_ model: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: model.appendingPathComponent("test_wavs/zh.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    }
}
