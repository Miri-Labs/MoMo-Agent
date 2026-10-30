@preconcurrency import AVFoundation
import Foundation
import os
import MoMoContracts
import MoMoSpeech

/// Small, separate performance probe. It never contributes samples or scores to the quality corpus.
enum SpeechDiagnosticsRun {
    private static let officialSHA256 = "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"

    static func run(arguments: [String]) async throws {
        if arguments.count > 4 {
            try await SpeechStressRun.run(arguments: arguments)
            return
        }
        guard arguments.count == 4, !arguments[3].isEmpty else {
            throw DiagnosticFailure.invalid("Usage: SpeechQuality --diagnostics MODEL_DIRECTORY OFFICIAL_ZH_WAV NEW_OUTPUT_DIRECTORY SOURCE_VERSION")
        }
        let modelURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let sourceURL = URL(fileURLWithPath: arguments[1])
        let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              try ContentHash.sha256(fileAt: sourceURL) == officialSHA256 else {
            throw DiagnosticFailure.invalid("Use the pinned official zh.wav and a new output directory")
        }
        let voice = try readVoice(sourceURL)
        let bundle = try SpeechModelBundle.load(from: modelURL)
        let configuration = try SpeechConfiguration()
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try WireJSON.encode(DiagnosticRunMetadata(schemaVersion: 1, sourceVersion: arguments[3],
            sourceSHA256: officialSHA256, configuration: configuration, modelManifest: bundle.manifest,
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            scope: "Mac software diagnostic; synthetic repeated speech; no CER, Watch, hardware temperature or background result"))
            .write(to: outputURL.appendingPathComponent("run.json"), options: .atomic)

        for seconds in [60, 180] {
            let directory = outputURL.appendingPathComponent("speech-\(seconds)s", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let inputs = try makeInputs(voice: voice, seconds: seconds, directory: directory)
            let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
            let engine = try SpeechEngine(bundle: bundle, configuration: configuration,
                onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
            let windows = try await prepareAll(engine: engine, inputs: inputs)
            let initialPrepareCount = observations.withLock { $0.count }
            let replayed = try await prepareAll(engine: engine, inputs: inputs)
            guard windows == replayed, !windows.isEmpty else {
                throw DiagnosticFailure.invalid("Repeated preparation changed window identities or found no speech")
            }
            var baseline: [SpeechRecognition] = []
            for window in windows { baseline.append(try await engine.transcribe(window: window, inputs: inputsFor(window, in: inputs))) }
            let baselineObservations = observations.withLock { $0 }
            try WireJSON.encode(baselineObservations).write(to: directory.appendingPathComponent("fresh-reader-observations.json"), options: .atomic)
            observations.withLock { $0.removeAll() }
            var sequence: SpeechTranscriptionSequence?, anchor: Int64?
            do {
                for (index, window) in windows.enumerated() {
                    if anchor != window.analysisAnchor {
                        if let sequence { await engine.close(sequence) }
                        sequence = try engine.makeTranscriptionSequence(inputs: inputs, anchor: window.analysisAnchor)
                        anchor = window.analysisAnchor
                    }
                    guard let sequence else { throw DiagnosticFailure.invalid("Missing sequential reader") }
                    let result = try await engine.transcribe(window: window, sequence: sequence)
                    let old = baseline[index]
                    guard result.windowID == old.windowID, result.text == old.text, result.tokens == old.tokens,
                          result.timestamps == old.timestamps, result.configurationFingerprint == old.configurationFingerprint else {
                        throw DiagnosticFailure.invalid("Sequential recognition differs from fresh-reader result")
                    }
                }
                if let sequence { await engine.close(sequence) }
            } catch {
                if let sequence { await engine.close(sequence) }
                throw error
            }
            try WireJSON.encode(["comparedWindows": windows.count, "exactRecognitionMatches": baseline.count])
                .write(to: directory.appendingPathComponent("sequential-equivalence.json"), options: .atomic)
            let values = baselineObservations.filter { $0.operation == .prepare } + observations.withLock { $0 }
            let transcriptions = values.filter { $0.operation == .transcribe }
            let uniqueCoreFrames = try FrameRange.union(windows.map(\.coreFrames)).reduce(Int64(0)) { $0 + $1.count }
            let report = WorkloadDiagnostic(seconds: seconds, uniqueCoreModelFrames: uniqueCoreFrames,
                windows: windows, serializedWindowBytes: try WireJSON.encode(windows).count, repeatedPreparationMatched: true,
                replayPreparationConvertedFrames: values.dropFirst(initialPrepareCount).filter { $0.operation == .prepare }
                    .reduce(0) { $0 + $1.convertedModelFrames },
                transcriptionConvertedFrames: transcriptions.reduce(0) { $0 + $1.convertedModelFrames },
                transcriptionDiscardedPrefixFrames: transcriptions.reduce(0) { $0 + $1.discardedPrefixModelFrames },
                observations: values)
            try WireJSON.encode(report).write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
            print("Diagnostic \(seconds)s: \(windows.count) windows; \(report.transcriptionDiscardedPrefixFrames) prefix frames decoded and discarded")
            if seconds == 60 {
                guard let longest = windows.first(where: { $0.modelCoreFrames.count == configuration.maximumCoreFrames }) else {
                    throw DiagnosticFailure.invalid("Stress input did not produce a full 20-second core")
                }
                try await cancelNative(bundle: bundle, configuration: configuration, window: longest,
                                       inputs: inputsFor(longest, in: inputs), outputURL: outputURL)
            }
        }
        print("Diagnostic reports saved separately from the quality baseline.")
    }

    static func inputsFor(_ window: SpeechWindow, in inputs: [SpeechAudioInput]) -> [SpeechAudioInput] {
        inputs.filter {
            $0.envelope.manifest.frames.end > window.analysisAnchor
                && $0.envelope.manifest.frames.start < window.contextFrames.end
        }
    }

    private static func prepareAll(engine: SpeechEngine, inputs: [SpeechAudioInput]) async throws -> [SpeechWindow] {
        guard let end = inputs.last?.envelope.manifest.frames.end else { throw DiagnosticFailure.invalid("Empty input") }
        var checkpoint: SpeechCheckpoint?
        var cursor: Int64 = 0
        var windows: [SpeechWindow] = []
        while cursor < end {
            let batch = try await engine.prepare(inputs: inputs, resume: checkpoint, epochClosed: true)
            guard let next = batch.checkpoint, next.sourceFrame > cursor, next.sourceFrame <= end,
                  !batch.waitingForMoreAudio else { throw DiagnosticFailure.invalid("Closed analysis did not advance") }
            windows.append(contentsOf: batch.windows)
            checkpoint = next
            cursor = next.sourceFrame
        }
        guard Set(windows.map(\.id)).count == windows.count else { throw DiagnosticFailure.invalid("Duplicate window") }
        return windows
    }

    private static func cancelNative(bundle: SpeechModelBundle, configuration: SpeechConfiguration,
                                     window: SpeechWindow, inputs: [SpeechAudioInput], outputURL: URL) async throws {
        let attempt = SpeechAttempt()
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let delayedCancellation = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)
        let cancellationArmed = OSAllocatedUnfairLock(initialState: true)
        let engine = try SpeechEngine(bundle: bundle, configuration: configuration,
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { event in
                switch event {
                case .analysisPageReady: break
                case .nativeDecodeStarted:
                    guard cancellationArmed.withLock({ $0 }) else { return }
                    let work = DispatchWorkItem { attempt.cancel() }
                    delayedCancellation.withLock { $0 = work }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(10), execute: work)
                case .nativeDecodeReturned:
                    delayedCancellation.withLock { $0?.cancel(); $0 = nil }
                }
            })
        var cancelled = false
        do { _ = try await engine.transcribe(window: window, inputs: inputs, attempt: attempt) }
        catch SpeechError.cancelled { cancelled = true }
        let values = observations.withLock { $0 }
        let overlap = values.contains { $0.cancellationDuringNativeDecode && $0.outcome == .cancelled }
        let report = NativeCancellationDiagnostic(requestDelayMilliseconds: 10,
            cancellationDiscardedResult: cancelled, observedCancellationInsideNative: overlap, observations: values)
        try WireJSON.encode(report).write(to: outputURL.appendingPathComponent("native-cancellation.json"), options: .atomic)
        guard cancelled, overlap else {
            throw DiagnosticFailure.invalid("Cancellation did not overlap actual C decode; report retained, no cancellation latency claim")
        }
        cancellationArmed.withLock { $0 = false }
        // Confirm the queue and recognizer remain usable after the real C call returns.
        _ = try await engine.transcribe(window: window, inputs: inputs)
        try WireJSON.encode(observations.withLock { $0 }).write(to: outputURL.appendingPathComponent("native-cancellation-and-reuse.json"), options: .atomic)
    }

    static func readVoice(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length == 89_472, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 89_472) else {
            throw DiagnosticFailure.invalid("Unexpected official fixture format")
        }
        try file.read(into: buffer)
        guard buffer.frameLength == 89_472, let pointer = buffer.floatChannelData?[0] else {
            throw DiagnosticFailure.invalid("Could not decode the fixture")
        }
        return (8_000..<78_000).map { Int16(max(-32_768, min(32_767, (pointer[$0] * 32_767).rounded()))) }
    }

    static func makeInputs(voice: [Int16], seconds: Int, directory: URL) throws -> [SpeechAudioInput] {
        let sessionID = UUID(), epochID = UUID(), deviceID = UUID()
        var inputs: [SpeechAudioInput] = []
        let frameCount = seconds * 16_000
        for start in stride(from: 0, to: frameCount, by: 960_000) {
            let count = min(960_000, frameCount - start)
            let url = directory.appendingPathComponent("\(start).wav")
            var data = Data()
            func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
            func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
            u32(16_000); u32(32_000); u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
            for frame in start..<(start + count) { u16(UInt16(bitPattern: voice[frame % voice.count])) }
            try data.write(to: url, options: .withoutOverwriting)
            let manifest = try ChunkManifest(sessionID: sessionID, epochID: epochID, chunkID: UUID(), sourceDeviceID: deviceID,
                sourceBuild: "speech-diagnostics-v1", sequence: Int64(inputs.count), frames: FrameRange(start: Int64(start), count: Int64(count)),
                timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0,
                codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: Int64(count),
                byteCount: Int64(data.count), audioSHA256: ContentHash.sha256(data),
                sealedAt: Date(timeIntervalSince1970: Double(start + count) / 16_000), sourceKind: .fixture)
            inputs.append(SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: url))
        }
        try WireJSON.encode(inputs.map(\.envelope.manifest)).write(to: directory.appendingPathComponent("inputs.json"), options: .atomic)
        return inputs
    }
}

private enum DiagnosticFailure: Error { case invalid(String) }
private struct DiagnosticRunMetadata: Encodable {
    let schemaVersion: Int
    let sourceVersion: String
    let sourceSHA256: String
    let configuration: SpeechConfiguration
    let modelManifest: SpeechModelManifest
    let platform: String
    let scope: String
}
private struct WorkloadDiagnostic: Encodable {
    let seconds: Int
    let uniqueCoreModelFrames: Int64
    let windows: [SpeechWindow]
    let serializedWindowBytes: Int
    let repeatedPreparationMatched: Bool
    let replayPreparationConvertedFrames: Int64
    let transcriptionConvertedFrames: Int64
    let transcriptionDiscardedPrefixFrames: Int64
    let observations: [SpeechDiagnostics]
}
private struct NativeCancellationDiagnostic: Encodable {
    let requestDelayMilliseconds: Int
    let cancellationDiscardedResult: Bool
    let observedCancellationInsideNative: Bool
    let observations: [SpeechDiagnostics]
}
