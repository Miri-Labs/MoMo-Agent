import Foundation
import os
import MoMoContracts

/// Archive analysis can wait for consumer demand; microphone analysis must remain independent.
public final class SpeechEngine: @unchecked Sendable {
    public let configurationFingerprint: String
    public let previousConfigurationFingerprints: [String]
    public let continuousArchive: Bool
    private let bundle: SpeechModelBundle
    private let configuration: SpeechConfiguration
    private let recognitionBackend: SpeechRecognitionBackend
    private let coreMLCacheDirectory: URL?
    private let onEvent: @Sendable (SpeechExecutionEvent) -> Void
    private let onDiagnostics: @Sendable (SpeechDiagnostics) -> Void
    private let queue = DispatchQueue(label: "MoMoAgent.speech", qos: .default, autoreleaseFrequency: .workItem)
    private let analysisQueue = DispatchQueue(label: "MoMoAgent.speech.analysis", qos: .default)
    private let dictationQueue = DispatchQueue(label: "MoMoAgent.speech.dictation", qos: .userInitiated,
                                               autoreleaseFrequency: .workItem)
    private let validationLock = NSLock()
    private var validated = false // Protected by validationLock; model files are immutable bundle resources.
    private var runtime: SherpaRuntime?
    private var speakerRuntime: SpeakerRuntime?
    private let speakerDirectory: URL?
    private var runtimeLanguage: SpeechLanguage? // Confined to queue.
    private var runtimeDownload: DownloadedSpeechModel? // Confined to queue.
    private struct Selection { var download: DownloadedSpeechModel?; var language: SpeechLanguage }
    private let selection: OSAllocatedUnfairLock<Selection>
    private let selectedVADThreshold: OSAllocatedUnfairLock<Float>
    private var vadContexts: [VADContinuation] = [] // Confined to analysisQueue; at most four epochs.
    private var idleVAD: (detector: SherpaVAD, threshold: Float)?
    private var dictationVAD: (detector: SherpaVAD, threshold: Float)? // Confined to dictationQueue.
    private let sequenceOwner = UUID()
    private let preparedAudio = PreparedAudioCache()

    public convenience init(bundle: SpeechModelBundle, configuration: SpeechConfiguration,
                            continuousArchive: Bool = false,
                            recognitionBackend: SpeechRecognitionBackend = .sherpa,
                            coreMLCacheDirectory: URL? = nil,
                            speakerDirectory: URL? = nil,
                            downloadedModel: DownloadedSpeechModel? = nil,
                            onEvent: @escaping @Sendable (SpeechExecutionEvent) -> Void = { _ in }) throws {
        try self.init(bundle: bundle, configuration: configuration, continuousArchive: continuousArchive,
                      recognitionBackend: recognitionBackend,
                      coreMLCacheDirectory: coreMLCacheDirectory,
                      speakerDirectory: speakerDirectory,
                      downloadedModel: downloadedModel,
                      onDiagnostics: { _ in }, onEvent: onEvent)
    }

    public init(bundle: SpeechModelBundle, configuration: SpeechConfiguration,
                continuousArchive: Bool = false,
                recognitionBackend: SpeechRecognitionBackend = .sherpa,
                coreMLCacheDirectory: URL? = nil,
                speakerDirectory: URL? = nil,
                downloadedModel: DownloadedSpeechModel? = nil,
                onDiagnostics: @escaping @Sendable (SpeechDiagnostics) -> Void,
                onEvent: @escaping @Sendable (SpeechExecutionEvent) -> Void) throws {
        try configuration.validate()
        if downloadedModel != nil,
           !SpeechModelChoice.funASRNano.supports(SpeechLanguage(rawValue: configuration.language)!) {
            throw SpeechModelSelectionError.unsupportedLanguage
        }
        self.bundle = bundle; self.configuration = configuration
        self.recognitionBackend = recognitionBackend
        self.coreMLCacheDirectory = coreMLCacheDirectory
        self.speakerDirectory = speakerDirectory
        selection = OSAllocatedUnfairLock(initialState: Selection(download: downloadedModel,
            language: SpeechLanguage(rawValue: configuration.language)!))
        self.onEvent = onEvent
        self.onDiagnostics = onDiagnostics
        self.continuousArchive = continuousArchive
        configurationFingerprint = try bundle.fingerprint(configuration: configuration,
            rule: continuousArchive ? "silero6-cut-merge-v6" : SpeechConfiguration.analysisRuleVersion)
        // Prefer the latest completed history. Older provenance remains in the archive.
        let previous = try SpeechModelManifest(asrSHA256: bundle.manifest.asrSHA256,
            tokensSHA256: bundle.manifest.tokensSHA256,
            vadSHA256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
        let previousBundle = SpeechModelBundle(directory: bundle.directory, manifest: previous)
        let candidates = continuousArchive ? [
            try bundle.fingerprint(configuration: configuration, rule: "silero6-bounded-speech-v5"),
            try bundle.fingerprint(configuration: configuration, rule: "silero6-pause-aligned-v4"),
            try bundle.fingerprint(configuration: configuration, rule: "silero6-speech-only-v3"),
            try bundle.fingerprint(configuration: configuration, rule: "silero6-selective-archive-v2"),
            try bundle.fingerprint(configuration: configuration, rule: "silero6-complete-coverage-v1"),
            try previousBundle.fingerprint(configuration: configuration, rule: "silero6-bounded-speech-v5"),
            try previousBundle.fingerprint(configuration: configuration)
        ] : []
        let current = configurationFingerprint
        previousConfigurationFingerprints = candidates.filter { $0 != current }
        selectedVADThreshold = OSAllocatedUnfairLock(initialState: configuration.threshold)
    }

    public var recognitionLanguage: SpeechLanguage { selection.withLock { $0.language } }
    public var recognitionModel: SpeechModelChoice { selection.withLock { $0.download == nil ? .senseVoice : .funASRNano } }
    /// Bounds peak encoder memory. Nano's unchanged encoder accepts batch=1.
    public var archiveBatchSize: Int { recognitionModel == .senseVoice ? 2 : 1 }

    public func archiveText(_ result: SpeechRecognition, window: SpeechWindow,
                            after previous: (result: SpeechRecognition, window: SpeechWindow)? = nil) -> String {
        continuousArchive ? result.textOwned(by: window, after: previous) : result.text
    }

    /// Runs between windows on the same queue as decoding. A failed load leaves the old choice selected.
    public func selectRecognitionModel(_ download: DownloadedSpeechModel?, attempt: SpeechAttempt = SpeechAttempt()) async throws {
        try await perform(operation: .warmUp, attempt: attempt, checkAfterOperation: false) { [self] recorder in
            let previous = selection.withLock { $0.download }
            guard previous != download else { return }
            if download != nil, !SpeechModelChoice.funASRNano.supports(recognitionLanguage) {
                throw SpeechModelSelectionError.unsupportedLanguage
            }
            clearRuntime()
            let language = recognitionLanguage
            let candidate = try makeRuntime(download: download, language: language, attempt: attempt, recorder: recorder)
            do {
                try candidate.warmUp(attempt: attempt, recorder: recorder)
                try attempt.checkCancellation()
                try selection.withLock {
                    if download != nil, !SpeechModelChoice.funASRNano.supports($0.language) {
                        throw SpeechModelSelectionError.unsupportedLanguage
                    }
                    $0.download = download
                }
            } catch { candidate.close(); throw error }
            // Publish the selection only after validation and warmup complete. A
            // cancellation after this commit must not report a failed switch.
            runtime = candidate
            runtimeLanguage = language
            runtimeDownload = download
        }
    }

    /// Each recognition request snapshots this value; analysis checkpoints keep their existing identity.
    public func setRecognitionLanguage(_ language: SpeechLanguage) throws {
        try selection.withLock {
            if $0.download != nil, !SpeechModelChoice.funASRNano.supports(language) {
                throw SpeechModelSelectionError.unsupportedLanguage
            }
            $0.language = language
        }
    }

    public var voiceActivityThreshold: Float { selectedVADThreshold.withLock { $0 } }

    /// Applies at the next analysis boundary. Existing coverage and queued windows retain their identity.
    public func setVoiceActivityThreshold(_ threshold: Float) throws {
        _ = try configuration.withVADThreshold(threshold)
        selectedVADThreshold.withLock { $0 = threshold }
    }

    deinit {
        if let runtime { queue.async { runtime.close() } }
        let speakers = speakerRuntime
        queue.async { withExtendedLifetime(speakers) {} }
        let contexts = vadContexts
        let idle = idleVAD
        analysisQueue.async { withExtendedLifetime((contexts, idle)) {} }
        let microphoneVAD = dictationVAD
        dictationQueue.async { withExtendedLifetime(microphoneVAD) {} }
    }

    public func prepare(inputs: [SpeechAudioInput], resume: SpeechCheckpoint? = nil,
                        epochClosed: Bool, attempt: SpeechAttempt = SpeechAttempt()) async throws -> SpeechAnalysisBatch {
        let boundary: AudioProcessingBoundary = inputs.last.map {
            epochClosed ? .receivedSnapshot($0.envelope.manifest.frames.end) : .open
        } ?? .open
        return try await prepare(inputs: inputs, resume: resume,
            boundary: boundary, attempt: attempt)
    }

    public func prepare(inputs: [SpeechAudioInput], resume: SpeechCheckpoint? = nil,
                        boundary: AudioProcessingBoundary, replayOrigin: Int64? = nil, attempt: SpeechAttempt = SpeechAttempt()) async throws -> SpeechAnalysisBatch {
        try await perform(operation: .prepare, attempt: attempt) { [self] recorder in
            let anchor = resume?.sourceFrame ?? 0
            let input = try SpeechInputSet(inputs, anchor: anchor, through: boundary.endFrame)
            if let resume {
                guard resume.sessionID == input.sessionID, resume.epochID == input.epochID,
                      resume.configurationFingerprint == configurationFingerprint else {
                    throw SpeechError.incompatibleCheckpoint
                }
            }
            recorder.value.inputModelFrames = input.modelFrameCount
            let result = try analyze(input: input, boundary: boundary, replayOrigin: replayOrigin, attempt: attempt, recorder: recorder)
            recorder.value.outputWindowCount = result.windows.count
            return result
        }
    }

    public func prepareStream(inputs: [SpeechAudioInput], resume: SpeechCheckpoint? = nil,
                              boundary: AudioProcessingBoundary, replayOrigin: Int64? = nil, readAheadAllowed: Bool = true,
                              attempt: SpeechAttempt = SpeechAttempt()) -> SpeechAnalysisStream {
        let owner = UUID()
        let channel = SpeechAnalysisChannel(attempt: attempt, readAheadAllowed: readAheadAllowed) { [preparedAudio] in
            preparedAudio.discard(owner: owner)
        }
        let producer = Task { [self] in
            do {
                _ = try await perform(operation: .prepare, attempt: attempt) { [self] recorder in
                    let input = try SpeechInputSet(inputs, anchor: resume?.sourceFrame ?? 0, through: boundary.endFrame)
                    if let resume {
                        guard resume.sessionID == input.sessionID, resume.epochID == input.epochID,
                              resume.configurationFingerprint == configurationFingerprint else { throw SpeechError.incompatibleCheckpoint }
                    }
                    recorder.value.inputModelFrames = input.modelFrameCount
                    try channel.waitForDemand(recorder: recorder)
                    if continuousArchive {
                        let result = try analyze(input: input, boundary: boundary, replayOrigin: replayOrigin,
                            attempt: attempt, recorder: recorder)
                        try publishArchiveAnalysis(result, input: input, channel: channel, recorder: recorder)
                        return result
                    }
                    return try analyze(input: input, boundary: boundary, replayOrigin: replayOrigin, attempt: attempt,
                                       recorder: recorder, stream: (channel, owner))
                }
                channel.finish(.success(()))
            } catch {
                preparedAudio.discard(owner: owner)
                channel.finish(.failure(error))
            }
        }
        return SpeechAnalysisStream(state: channel, producer: producer)
    }

    public func discardPreparedAudio(sessionID: UUID? = nil) { preparedAudio.discard(sessionID: sessionID) }

    /// Runs validation and model preparation on the recognition queue; concurrent callers reuse one runtime.
    public func warmUp(attempt: SpeechAttempt = SpeechAttempt()) async throws {
        try await perform(operation: .warmUp, attempt: attempt) { [self] recorder in
            try native(attempt: attempt, recorder: recorder).warmUp(attempt: attempt, recorder: recorder)
        }
    }

    /// Short microphone input shares the loaded recognizer, without creating an archive recording.
    public func dictate(samples: [Float], attempt: SpeechAttempt = SpeechAttempt()) async throws -> String {
        guard !samples.isEmpty, samples.count <= 120 * SpeechConfiguration.sampleRate,
              samples.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio("dictation_length_or_samples") }
        let ranges: [Range<Int>] = try await perform(operation: .prepareDictation, attempt: attempt) { [self] recorder in
            try validateBundle(attempt: attempt, recorder: recorder)
            let threshold = voiceActivityThreshold
            let detector: SherpaVAD
            if let idle = dictationVAD, idle.threshold == threshold {
                detector = idle.detector
            } else {
                detector = try SherpaVAD(model: bundle.directory.appendingPathComponent("silero_vad.onnx"),
                    configuration: configuration.withVADThreshold(threshold))
            }
            detector.reset()
            defer { detector.reset(); dictationVAD = (detector, threshold) }
            var detected: [Range<Int64>] = []
            for start in stride(from: 0, to: samples.count, by: 512) {
                try attempt.checkCancellation()
                let end = min(start + 512, samples.count)
                var frame = Array(samples[start..<end])
                frame += repeatElement(0, count: 512 - frame.count)
                try detector.accept(frame)
                // Bound the native VAD's retained audio even during uninterrupted speech.
                if (start + 512) % (16 * 16_000) == 0 { detector.flush() }
                detected += try detector.drain()
            }
            detector.flush()
            detected += try detector.drain()
            return DictationWindows.make(detected, sampleCount: samples.count,
                maximumFrames: Int(configuration.maximumCoreFrames), padding: Int(configuration.paddingFrames))
        }
        var text: [String] = []
        for range in ranges {
            let result = try await perform(operation: .dictate, attempt: attempt) { [self] recorder in
                let result = try native(attempt: attempt, recorder: recorder)
                    .recognize(samples: Array(samples[range]), windowID: attempt.id.uuidString,
                        fingerprint: configurationFingerprint, attempt: attempt, onEvent: { _ in }, recorder: recorder)
                return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !result.isEmpty { text.append(result) }
        }
        return text.joined(separator: " ")
    }

    public func transcribe(window: SpeechWindow, inputs: [SpeechAudioInput],
                           attempt: SpeechAttempt = SpeechAttempt()) async throws -> SpeechRecognition {
        return try await perform(operation: .transcribe, windowID: window.id, attempt: attempt) { [self] recorder in
            let input = try SpeechInputSet(inputs, anchor: window.analysisAnchor)
            let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
            guard window.modelCoreFrames.count <= configuration.maximumCoreFrames,
                  window.modelContextFrames.contains(window.modelCoreFrames),
                  window.modelContextFrames.count <= configuration.maximumRecognitionFrames,
                  window.modelContextFrames.end <= input.modelFrameCount,
                  try planner.makeWindow(core: window.modelCoreFrames, context: window.modelContextFrames, input: input) == window else {
                throw SpeechError.incompatibleWindow
            }
            recorder.value.inputModelFrames = input.modelFrameCount
            recorder.value.coreModelFrames = window.modelCoreFrames.count
            let samples = try cachedSamples(window: window, input: input, attempt: attempt, recorder: recorder)
                ?? samples(for: window.modelContextFrames, input: input, attempt: attempt, recorder: recorder)
            let coreStart = Int(window.modelCoreFrames.start - window.modelContextFrames.start)
            let coreRange = coreStart..<(coreStart + Int(window.modelCoreFrames.count))
            return try recognizeArchive([.init(samples: samples, windowID: window.id, coreRange: coreRange)],
                attempt: attempt, recorder: recorder)[0]
        }
    }

    public func makeTranscriptionSequence(inputs: [SpeechAudioInput], anchor: Int64) throws -> SpeechTranscriptionSequence {
        try SpeechTranscriptionSequence(owner: sequenceOwner, input: SpeechInputSet(inputs, anchor: anchor))
    }

    /// Waits for queued native work before disposing the reader; cancellation cannot skip this cleanup.
    public func close(_ sequence: SpeechTranscriptionSequence) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if sequence.owner == sequenceOwner { sequence.cursor = nil; sequence.closed = true }
                continuation.resume()
            }
        }
    }

    public func transcribe(window: SpeechWindow, sequence: SpeechTranscriptionSequence,
                           attempt: SpeechAttempt = SpeechAttempt()) async throws -> SpeechRecognition {
        do {
            return try await perform(operation: .transcribe, windowID: window.id, attempt: attempt) { [self] recorder in
                let input = sequence.input
                let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
                guard sequence.owner == sequenceOwner, !sequence.closed,
                      window.modelCoreFrames.start >= sequence.previousCoreEnd,
                      window.modelCoreFrames.count <= configuration.maximumCoreFrames,
                      window.modelContextFrames.contains(window.modelCoreFrames),
                      window.modelContextFrames.count <= configuration.maximumRecognitionFrames,
                      window.modelContextFrames.end <= input.modelFrameCount,
                      try planner.makeWindow(core: window.modelCoreFrames, context: window.modelContextFrames, input: input) == window else {
                    throw SpeechError.incompatibleWindow
                }
                recorder.value.inputModelFrames = input.modelFrameCount
                recorder.value.coreModelFrames = window.modelCoreFrames.count
                let samples: [Float]
                if let cached = try cachedSamples(window: window, input: input, attempt: attempt, recorder: recorder) {
                    samples = cached
                } else {
                    if sequence.cursor == nil {
                        sequence.cursor = try SequentialSpeechSamples(input: input, configuration: configuration,
                                                                      attempt: attempt, recorder: recorder)
                    }
                    guard let cursor = sequence.cursor else { throw SpeechError.incompatibleWindow }
                    samples = try cursor.samples(for: window.modelContextFrames, sourceContext: window.contextFrames,
                                                 attempt: attempt, recorder: recorder)
                }
                let coreStart = Int(window.modelCoreFrames.start - window.modelContextFrames.start)
                let coreRange = coreStart..<(coreStart + Int(window.modelCoreFrames.count))
                let result = try recognizeArchive([.init(samples: samples, windowID: window.id, coreRange: coreRange)],
                    attempt: attempt, recorder: recorder)[0]
                sequence.previousCoreEnd = window.modelCoreFrames.end
                return result
            }
        } catch {
            await close(sequence)
            throw error
        }
    }

    private func cachedSamples(window: SpeechWindow, input: SpeechInputSet, attempt: SpeechAttempt,
                               recorder: SpeechDiagnosticRecorder) throws -> [Float]? {
        guard let samples = preparedAudio.take(window) else { return nil }
        for item in input.inputs where item.envelope.manifest.frames.start < window.contextFrames.end
            && item.envelope.manifest.frames.end > window.contextFrames.start {
            try validateSpeechAudioIdentity(item, attempt: attempt, recorder: recorder)
        }
        recorder.value.preparedAudioModelFrames += Int64(samples.count)
        return samples
    }

    /// Already received archive windows only. Dictation never enters this batching path.
    public func transcribe(windows: [SpeechWindow], sequence: SpeechTranscriptionSequence,
                           attempt: SpeechAttempt = SpeechAttempt()) async throws -> [SpeechRecognition] {
        // A model switch can be queued after the coordinator claims two windows.
        // Nano handles that already-claimed pair sequentially on its batch=1 graph.
        guard !windows.isEmpty, windows.count <= 2 else { throw SpeechError.incompatibleWindow }
        if windows.count == 1 {
            return [try await transcribe(window: windows[0], sequence: sequence, attempt: attempt)]
        }
        do {
            return try await perform(operation: .transcribe, windowID: windows[0].id, attempt: attempt) { [self] recorder in
                guard sequence.owner == sequenceOwner, !sequence.closed else { throw SpeechError.incompatibleWindow }
                let input = sequence.input
                let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
                var previousEnd = sequence.previousCoreEnd
                var prepared: [SherpaRecognitionInput] = []
                for window in windows {
                    try attempt.checkCancellation()
                    guard window.modelCoreFrames.start >= previousEnd,
                          window.modelCoreFrames.count <= configuration.maximumCoreFrames,
                          window.modelContextFrames.contains(window.modelCoreFrames),
                          window.modelContextFrames.count <= configuration.maximumRecognitionFrames,
                          window.modelContextFrames.end <= input.modelFrameCount,
                          try planner.makeWindow(core: window.modelCoreFrames, context: window.modelContextFrames, input: input) == window else {
                        throw SpeechError.incompatibleWindow
                    }
                    let samples: [Float]
                    if let cached = try cachedSamples(window: window, input: input, attempt: attempt, recorder: recorder) {
                        samples = cached
                    } else {
                        if sequence.cursor == nil {
                            sequence.cursor = try SequentialSpeechSamples(input: input, configuration: configuration,
                                attempt: attempt, recorder: recorder)
                        }
                        guard let cursor = sequence.cursor else { throw SpeechError.incompatibleWindow }
                        samples = try cursor.samples(for: window.modelContextFrames, sourceContext: window.contextFrames,
                            attempt: attempt, recorder: recorder)
                    }
                    let coreStart = Int(window.modelCoreFrames.start - window.modelContextFrames.start)
                    let coreRange = coreStart..<(coreStart + Int(window.modelCoreFrames.count))
                    prepared.append(.init(samples: samples, windowID: window.id, coreRange: coreRange))
                    previousEnd = window.modelCoreFrames.end
                    recorder.value.coreModelFrames += window.modelCoreFrames.count
                }
                recorder.value.inputModelFrames = input.modelFrameCount
                recorder.value.outputWindowCount = windows.count
                let results = try recognizeArchive(prepared, attempt: attempt, recorder: recorder)
                try attempt.checkCancellation()
                sequence.previousCoreEnd = previousEnd
                return results
            }
        } catch {
            await close(sequence)
            throw error
        }
    }

    private func recognizeArchive(_ inputs: [SherpaRecognitionInput], attempt: SpeechAttempt,
                                  recorder: SpeechDiagnosticRecorder) throws -> [SpeechRecognition] {
        try attempt.checkCancellation()
        guard Set(inputs.map(\.windowID)).count == inputs.count,
              inputs.allSatisfy({ !$0.samples.isEmpty }) else { throw SpeechError.incompatibleWindow }
        let useCoreSlice = recognitionModel == .funASRNano
        // Exact digital silence has no speech. Do not turn this into an energy threshold:
        // selected quiet speech must not be removed by another amplitude gate.
        var offsets: [String: Float] = [:]
        let audible = inputs.compactMap { input -> SherpaRecognitionInput? in
            let recognitionSamples: ArraySlice<Float>
            if useCoreSlice, let coreRange = input.coreRange,
               coreRange.lowerBound >= 0, coreRange.upperBound <= input.samples.count, !coreRange.isEmpty {
                recognitionSamples = input.samples[coreRange]
            } else {
                recognitionSamples = input.samples[...]
            }
            offsets[input.windowID] = Float(recognitionSamples.startIndex) / 16_000
            guard continuousArchive else { return .init(samples: Array(recognitionSamples), windowID: input.windowID) }
            guard let start = recognitionSamples.firstIndex(where: { $0 != 0 }),
                  let end = recognitionSamples.lastIndex(where: { $0 != 0 }) else { return nil }
            offsets[input.windowID] = Float(start) / 16_000
            return .init(samples: Array(recognitionSamples[start...end]), windowID: input.windowID)
        }
        let decoded = audible.isEmpty ? [] : try native(attempt: attempt, recorder: recorder)
            .recognizeBatch(audible, fingerprint: configurationFingerprint, attempt: attempt,
                onEvent: onEvent, recorder: recorder)
        recorder.value.recognitionInputModelFrames = audible.reduce(0) { $0 + Int64($1.samples.count) }
        guard decoded.count == audible.count, Set(decoded.map(\.windowID)) == Set(audible.map(\.windowID)) else {
            throw SpeechError.nativeResult
        }
        let results = Dictionary(uniqueKeysWithValues: decoded.map { ($0.windowID, $0) })
        try attempt.checkCancellation()
        return try inputs.map { input in
            guard let result = results[input.windowID] else {
                return SpeechRecognition(windowID: input.windowID, text: "", tokens: [], timestamps: [],
                    rawJSON: "{\"text\":\"\",\"reason\":\"digital_silence\"}", configurationFingerprint: configurationFingerprint)
            }
            let offset = offsets[input.windowID] ?? 0
            var aligned = SpeechRecognition(windowID: result.windowID, text: result.text, tokens: result.tokens,
                timestamps: result.timestamps.map { $0 + offset }, rawJSON: result.rawJSON,
                configurationFingerprint: result.configurationFingerprint)
            aligned.recognitionFingerprint = result.recognitionFingerprint
            if let speakerDirectory, !aligned.text.isEmpty {
                do {
                    if speakerRuntime == nil {
                        speakerRuntime = try SpeakerRuntime(directory: speakerDirectory, cacheRoot: coreMLCacheDirectory, attempt: attempt)
                    }
                    aligned.speakers = try speakerRuntime?.analyze(input.samples, attempt: attempt)
                    let turns = SpeakerTurn.plan(aligned.speakers ?? [], core: input.coreRange ?? input.samples.indices,
                        sampleBounds: input.samples.indices)
                    if !turns.isEmpty {
                        let timed = aligned.alignedSpeakerTurns(turns)
                        var transcribed = timed ?? []
                        // Keep the encoder's existing memory bound, including Nano's batch=1.
                        for start in stride(from: 0, to: timed == nil && turns.count > 1 ? turns.count : 0, by: archiveBatchSize) {
                            try attempt.checkCancellation()
                            let batch = Array(turns[start..<min(turns.count, start + archiveBatchSize)])
                            let clips = batch.enumerated().map { index, turn in
                                SherpaRecognitionInput(samples: Array(input.samples[turn.audioFrames]),
                                    windowID: "\(input.windowID):turn:\(start + index)")
                            }
                            let decodedTurns = try native(attempt: attempt, recorder: recorder).recognizeBatch(clips,
                                fingerprint: configurationFingerprint, attempt: attempt, onEvent: onEvent, recorder: recorder)
                            guard decodedTurns.count == batch.count else { throw SpeechError.nativeResult }
                            for (clip, turn) in zip(clips, batch) {
                                guard let decoded = decodedTurns.first(where: { $0.windowID == clip.windowID }) else { throw SpeechError.nativeResult }
                                // A failed short decode must not silently discard words from the original result.
                                guard decoded.text.contains(where: { $0.isLetter || $0.isNumber }) else { throw SpeechError.nativeResult }
                                transcribed.append(SpeakerTurnTranscript(text: decoded.text,
                                    start: Double(turn.frames.lowerBound) / 16_000, end: Double(turn.frames.upperBound) / 16_000,
                                    evidence: turn.evidence))
                            }
                            recorder.value.recognitionInputModelFrames = (recorder.value.recognitionInputModelFrames ?? 0)
                                + clips.reduce(0) { $0 + Int64($1.samples.count) }
                        }
                        // Preserve the successful original decode if every tiny turn decoded empty.
                        if !transcribed.isEmpty {
                            var split = SpeechRecognition(windowID: aligned.windowID, text: transcribed.map(\.text).joined(),
                                tokens: [], timestamps: [], rawJSON: aligned.rawJSON,
                                configurationFingerprint: aligned.configurationFingerprint)
                            split.recognitionFingerprint = aligned.recognitionFingerprint
                            split.speakers = aligned.speakers
                            split.speakerTurns = transcribed
                            aligned = split
                        }
                    }
                } catch {
                    try attempt.checkCancellation()
                    // A speaker failure must not discard a successfully decoded transcript.
                    aligned.speakerFailure = "speaker_inference_failed"
                    speakerRuntime = nil
                }
            }
            return aligned
        }
    }

    /// The reader and its file handle are released before entering the blocking native decode.
    private func samples(for range: FrameRange, input: SpeechInputSet, attempt: SpeechAttempt,
                         recorder: SpeechDiagnosticRecorder) throws -> [Float] {
        let reader = try EpochAudioReader(input: input, attempt: attempt, recorder: recorder)
        var position: Int64 = 0
        var samples: [Float] = []
        samples.reserveCapacity(Int(range.count))
        while let block = try reader.next() {
            let upper = position + Int64(block.count)
            let start = max(position, range.start)
            let end = min(upper, range.end)
            recorder.value.discardedPrefixModelFrames += max(0, min(upper, range.start) - position)
            recorder.value.discardedSuffixModelFrames += max(0, upper - max(position, range.end))
            if end > start { samples.append(contentsOf: block[Int(start - position)..<Int(end - position)]) }
            position = upper
            if position >= range.end { break }
        }
        guard samples.count == range.count else { throw SpeechError.missingAudio }
        return samples
    }

    private func perform<T: Sendable>(operation kind: SpeechDiagnostics.Operation, windowID: String? = nil,
                                     attempt: SpeechAttempt, checkAfterOperation: Bool = true,
                                     _ operation: @escaping @Sendable (SpeechDiagnosticRecorder) throws -> T) async throws -> T {
        let recorder = SpeechDiagnosticRecorder(operation: kind, attemptID: attempt.id, windowID: windowID,
                                                fingerprint: configurationFingerprint)
        if Task.isCancelled {
            attempt.cancel()
            onDiagnostics(recorder.finished(outcome: .cancelled, attempt: attempt))
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                let executor = kind == .prepareDictation ? dictationQueue : kind == .prepare ? analysisQueue : queue
                let qos: DispatchQoS = (kind == .prepareDictation || kind == .dictate) ? .userInitiated : .default
                executor.async(qos: qos) { [onDiagnostics] in
                    recorder.started()
                    do {
                        try attempt.checkCancellation()
                        let result = try operation(recorder)
                        if checkAfterOperation { try attempt.checkCancellation() }
                        onDiagnostics(recorder.finished(outcome: .completed, attempt: attempt))
                        continuation.resume(returning: result)
                    } catch {
                        let cancelled = error is CancellationError || (error as? SpeechError) == .cancelled
                        recorder.value.failureCode = (error as? SpeechError)?.diagnosticCode
                        onDiagnostics(recorder.finished(outcome: cancelled ? .cancelled : .failed, attempt: attempt))
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { attempt.cancel() }
    }

    private func native(attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder) throws -> SherpaRuntime {
        dispatchPrecondition(condition: .onQueue(queue))
        try attempt.checkCancellation()
        // Read the model and language together at the recognition boundary.
        let selected = selection.withLock { $0 }
        let download = selected.download, language = selected.language
        if let runtime, runtimeDownload == download, runtimeLanguage == language { return runtime }
        clearRuntime()
        let created = try makeRuntime(download: download, language: language, attempt: attempt, recorder: recorder)
        runtime = created
        runtimeLanguage = language
        runtimeDownload = download
        try attempt.checkCancellation()
        return created
    }

    private func clearRuntime() {
        runtime?.close()
        runtime = nil
        speakerRuntime = nil
        runtimeLanguage = nil
        runtimeDownload = nil
    }

    private func makeRuntime(download: DownloadedSpeechModel?, language: SpeechLanguage,
                             attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder) throws -> SherpaRuntime {
        try validateBundle(attempt: attempt, recorder: recorder)
        return try SherpaRuntime(bundle: bundle, configuration: configuration.withLanguage(language),
            backend: recognitionBackend, download: download, cacheRoot: coreMLCacheDirectory,
            attempt: attempt, recorder: recorder)
    }

    private func analyze(input: SpeechInputSet, boundary: AudioProcessingBoundary, replayOrigin: Int64?, attempt: SpeechAttempt,
                         recorder: SpeechDiagnosticRecorder,
                         stream: (channel: SpeechAnalysisChannel, owner: UUID)? = nil) throws -> SpeechAnalysisBatch {
        dispatchPrecondition(condition: .onQueue(analysisQueue))
        try validateBundle(attempt: attempt, recorder: recorder)
        let threshold = voiceActivityThreshold
        recorder.value.vadThreshold = threshold
        let context: VADContinuation
        if let index = vadContexts.firstIndex(where: { $0.canContinue(input, threshold: threshold) }) {
            context = vadContexts.remove(at: index)
            recorder.value.vadContinuationReused = true
        } else {
            let origin = replayOrigin ?? input.inputs[0].envelope.manifest.frames.start
            guard origin <= input.start, origin == 0 || replayOrigin != nil || input.start == origin else {
                throw SpeechError.incompatibleCheckpoint
            }
            let detector: SherpaVAD
            if let idle = idleVAD, idle.threshold == threshold {
                detector = idle.detector
                idleVAD = nil
            } else if let index = vadContexts.firstIndex(where: { $0.epochID == input.epochID && $0.threshold == threshold }) {
                detector = vadContexts.remove(at: index).detector
                detector.reset()
            } else {
                let started = DispatchTime.now().uptimeNanoseconds
                // Retain short pause candidates; the archive planner joins them into
                // context-rich recognition windows independently of display paragraphs.
                detector = try SherpaVAD(model: bundle.directory.appendingPathComponent("silero_vad.onnx"),
                    configuration: configuration.withVADThreshold(threshold,
                        minimumSilenceSeconds: continuousArchive ? 0.3 : 2))
                recorder.value.vadLoadSeconds += SpeechDiagnosticRecorder.seconds(since: started)
            }
            context = VADContinuation(input: input, origin: origin, threshold: threshold, detector: detector)
        }
        let rolloverBefore = context.rolloverReplayFrames
        defer {
            let replayed = context.rolloverReplayFrames - rolloverBefore
            recorder.value.vadModelFrames += replayed
            if replayed > 0 {
                recorder.value.vadReplayModelFrames = (recorder.value.vadReplayModelFrames ?? 0) + replayed
            }
        }
        do {
            if input.sampleRate == 16_000, context.origin + context.received < input.start {
                let replay = try SpeechInputSet(input.inputs, anchor: context.origin + context.received, through: input.start)
                let reader = try EpochAudioReader(input: replay, attempt: attempt, recorder: recorder)
                var frame = context.received
                while let samples = try reader.next() {
                    try context.append(samples, at: frame); frame += Int64(samples.count)
                    while try context.step(through: frame) {
                        try attempt.checkCancellation()
                        recorder.value.vadModelFrames += 512
                        recorder.value.vadReplayModelFrames = (recorder.value.vadReplayModelFrames ?? 0) + 512
                    }
                }
            }
            context.retain(from: context.offset(input.start))
            let result = try analyze(input: input, boundary: boundary, context: context,
                attempt: attempt, recorder: recorder, stream: stream)
            remember(context)
            return result
        } catch {
            if error as? SpeechError == .cancelled || error is CancellationError { remember(context) }
            throw error
        }
    }

    private func remember(_ context: VADContinuation) {
        vadContexts.removeAll { $0.epochID == context.epochID }
        if context.finalized {
            context.detector.reset()
            idleVAD = (context.detector, context.threshold)
        } else { vadContexts.append(context) }
        if vadContexts.count > 4 { vadContexts.removeFirst(vadContexts.count - 4) }
    }

    private func analyze(input: SpeechInputSet, boundary: AudioProcessingBoundary, context: VADContinuation,
                         attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder,
                         stream: (channel: SpeechAnalysisChannel, owner: UUID)?) throws -> SpeechAnalysisBatch {
        // A resampling converter must also see its prefix in one pass. Splitting the
        // converter at a checkpoint changes its phase even when the VAD state survives.
        let preserveContinuation: Bool
        if case .processingRange = boundary { preserveContinuation = input.sampleRate == 16_000 }
        else { preserveContinuation = false }
        let alignedEnd = context.origin + ((input.end - context.origin + 511) / 512) * 512
        let readerEnd = preserveContinuation ? min(alignedEnd, input.inputs.last!.envelope.manifest.frames.end) : input.end
        let readerInput = try SpeechInputSet(input.inputs,
            anchor: input.sampleRate == 16_000 ? input.start : context.origin, through: readerEnd)
        let reader = try EpochAudioReader(input: readerInput, attempt: attempt, recorder: recorder)
        let base = context.offset(input.start)
        var readerPosition = context.offset(readerInput.start)
        var readThrough: Int64 = 0
        var position: Int64 = max(0, context.processed - base)
        var ranges = context.relativeRanges(from: base, through: context.processed)
        let lookahead = configuration.paddingFrames * 2
            + Int64((configuration.minimumSpeechSeconds * 16_000).rounded(.up)) + 1_024
        let pageWindowTarget = input.modelFrameCount >= 2 * configuration.maximumCoreFrames ? archiveBatchSize : 1
        var audio = stream.map { _ in AnalysisAudioBuffer(capacity: Int(
            configuration.maximumCoreFrames * Int64(pageWindowTarget) + 256_000 + lookahead + 8_192)) }
        var published: [Int64: SpeechWindow] = [:]
        var publishedThrough: Int64 = 0
        var publishedSpeechThrough: Int64 = 0

        func publish(_ result: SpeechAnalysisBatch, final: Bool) throws {
            guard let stream else { return }
            for window in result.windows {
                if let previous = published[window.modelCoreFrames.start], previous != window {
                    throw SpeechError.incompatibleWindow
                }
            }
            let windows = result.windows.filter { published[$0.modelCoreFrames.start] == nil }
            for window in windows {
                if let samples = audio?.samples(in: window.modelContextFrames) {
                    try preparedAudio.put(owner: stream.owner, window: window, samples: samples, attempt: attempt)
                }
                published[window.modelCoreFrames.start] = window
                publishedSpeechThrough = max(publishedSpeechThrough, window.modelCoreFrames.end)
            }
            let page = SpeechAnalysisBatch(windows: windows, analyzedCoverage: result.analyzedCoverage,
                noSpeechCoverage: result.noSpeechCoverage, checkpoint: result.checkpoint,
                waitingForMoreAudio: result.waitingForMoreAudio)
            try stream.channel.send(SpeechAnalysisPage(batch: page, isFinal: final))
            recorder.value.outputWindowCount += windows.count
            onEvent(.analysisPageReady(windowCount: windows.count))
            if !final { try stream.channel.waitForDemand(recorder: recorder) }
        }

        while let decoded = try reader.next() {
            let prefixCount = min(decoded.count, Int(max(0, base - readerPosition)))
            if prefixCount > 0 {
                try context.append(Array(decoded.prefix(prefixCount)), at: readerPosition)
                while try context.step(through: readerPosition + Int64(prefixCount)) {
                    try attempt.checkCancellation()
                    recorder.value.vadModelFrames += 512
                    recorder.value.vadReplayModelFrames = (recorder.value.vadReplayModelFrames ?? 0) + 512
                }
            }
            let targetStart = readerPosition + Int64(prefixCount)
            readerPosition += Int64(decoded.count)
            let block = Array(decoded.dropFirst(prefixCount).prefix(Int(input.modelFrameCount - readThrough)))
            let available = Array(decoded.dropFirst(prefixCount))
            if available.isEmpty { continue }
            audio?.append(block)
            try context.append(preserveContinuation ? available : block, at: targetStart)
            readThrough += Int64(block.count)
            var firstPass = true
            while true {
                try attempt.checkCancellation()
                let vadThrough = preserveContinuation ? readerPosition : base + readThrough
                let caughtUp = firstPass && context.processed <= vadThrough
                let advanced = caughtUp ? false : try context.step(through: vadThrough)
                if advanced { recorder.value.vadModelFrames += 512 }
                guard advanced || caughtUp else { break }
                firstPass = false
                position = min(input.modelFrameCount, max(0, context.processed - base))
                let previousRanges = ranges
                ranges = context.relativeRanges(from: base, through: context.processed)
                let changed = ranges != previousRanges
                let speechEnd = ranges.last?.upperBound ?? 0
                if stream != nil {
                    let quiet = !context.detector.speechDetected && !context.lastFlushWasForced && position - speechEnd >= lookahead
                    // Keep the undecided VAD tail replayable even when no speech is detected yet.
                    let quietThrough = max(0, position - lookahead)
                    // Full cores can publish during speech; short tails wait for stable padding.
                    if changed
                        || (quiet && (speechEnd > publishedSpeechThrough || quietThrough - publishedThrough >= 160_000)) {
                        let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
                        let ready = try planner.windows(ranges: ranges, input: input, availableThrough: position, tailClosed: quiet)
                        let pending = ready.filter { published[$0.modelCoreFrames.start] == nil }
                        let hasNew = !pending.isEmpty
                        let through = quiet ? quietThrough : (ready.last?.modelCoreFrames.end ?? publishedThrough)
                        // Coalesce adjacent windows from the received snapshot.
                        // Bound extra VAD work to one core of already-local audio;
                        // a short tail publishes immediately, without another sync.
                        let batchReady = pending.count >= pageWindowTarget
                            || input.modelFrameCount - position <= 2 * lookahead
                            || pending.first.map { position - $0.modelCoreFrames.end >= configuration.maximumCoreFrames } == true
                        if (hasNew && batchReady) || (!hasNew && quiet && through - publishedThrough >= 160_000) {
                            let result = try batch(input: input, ranges: ranges, through: position, checkpoint: true,
                                                   tailClosed: quiet, waiting: false, coverageThrough: through)
                            try publish(result, final: false)
                            publishedThrough = through
                        }
                    }
                    continue
                }
                if !continuousArchive, position >= 160_000, !context.detector.speechDetected, !context.lastFlushWasForced, position - speechEnd >= lookahead {
                    // A new utterance may still be below VAD's minimum duration. Replay the
                    // undecided tail, just as the streaming path does, instead of committing silence.
                    return try batch(input: input, ranges: ranges, through: position, checkpoint: true,
                                     tailClosed: true, waiting: false, coverageThrough: position - lookahead)
                }
                // Continuous speech must also publish checkpoints. Keep the incomplete core
                // for the next pass; only full cores are committed, without inventing silence.
                if !continuousArchive, position >= 1_024_000 {
                    let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
                    let ready = try planner.windows(ranges: ranges, input: input, availableThrough: position, tailClosed: false)
                    if let safeEnd = ready.last?.modelCoreFrames.end, safeEnd > 0 {
                        return try batch(input: input, ranges: ranges, through: safeEnd, checkpoint: true,
                                         tailClosed: false, waiting: false)
                    }
                }
            }
        }
        if continuousArchive, boundary == .open {
            // A received prefix is not a recording end. Flushing here can discard
            // a sub-minimum speech onset and permanently commit it as silence.
            let ready = try batch(input: input, ranges: ranges, through: position, checkpoint: false,
                tailClosed: false, waiting: true, energy: context.relativeEnergy(from: base, through: base + position),
                hasPendingSpeech: context.detector.speechDetected || context.lastFlushWasForced)
            let quiet = !context.detector.speechDetected && !context.lastFlushWasForced
            // Preserve the planner's two-second join horizon and any undecided onset.
            let pendingFrames = 32_000 + lookahead
            var quietEnd = input.sourceFrame(forModelFrame: max(0, position - pendingFrames))
            if let undrained = context.undrainedSpeechFloor {
                quietEnd = min(quietEnd, input.sourceFrame(forModelFrame: max(0, undrained - base - lookahead)))
            }
            if !quiet, let speechEnd = ranges.last?.upperBound {
                quietEnd = min(quietEnd, input.sourceFrame(forModelFrame: max(0, speechEnd - pendingFrames)))
            }
            // A detected but not yet publishable range can never become silence,
            // even if a detector transition reports quiet at this boundary.
            for range in ranges {
                // Pending speech includes its onset/coda padding. Committing the
                // raw VAD onset as silence can lose the first syllable after resume.
                let lower = input.sourceFrame(forModelFrame: max(0, range.lowerBound - configuration.paddingFrames))
                let upper = input.sourceFrame(forModelFrame: min(position, range.upperBound + configuration.paddingFrames))
                if upper > lower, let unowned = try WindowPlanner.subtract(ready.windows.map(\.coreFrames),
                    from: FrameRange(start: lower, count: upper - lower)).first {
                    quietEnd = min(quietEnd, unowned.start)
                }
            }
            quietEnd = max(input.start, quietEnd)
            let safeEnd = max(quietEnd, ready.windows.last?.coreFrames.end ?? input.start)
            let result = try batch(input: input, ranges: ranges, through: position, checkpoint: safeEnd > input.start,
                tailClosed: false, waiting: true, finalSourceEnd: safeEnd,
                energy: context.relativeEnergy(from: base, through: base + position),
                hasPendingSpeech: context.detector.speechDetected || context.lastFlushWasForced)
            recorder.value.selectedArchiveModelFrames = result.windows.reduce(0) { $0 + $1.modelCoreFrames.count }
            recorder.value.skippedArchiveModelFrames = max(0, Int64(Double(safeEnd - input.start) * 16_000 / input.sampleRate)
                - (recorder.value.selectedArchiveModelFrames ?? 0))
            try publish(result, final: true)
            return result
        }
        if boundary.endFrame != nil {
            let before = context.processed
            try context.finish(padTail: boundary.endFrame != nil
                && (!preserveContinuation || context.processed < base + input.modelFrameCount))
            recorder.value.vadModelFrames += context.processed - before
            position = input.modelFrameCount
            ranges = context.relativeRanges(from: base, through: base + position)
            let result = try batch(input: input, ranges: ranges, through: position, checkpoint: true,
                                   tailClosed: true, waiting: false, finalSourceEnd: input.end,
                                   energy: context.relativeEnergy(from: base, through: base + position))
            if continuousArchive {
                recorder.value.selectedArchiveModelFrames = result.windows.reduce(0) { $0 + $1.modelCoreFrames.count }
                recorder.value.skippedArchiveModelFrames = input.modelFrameCount - (recorder.value.selectedArchiveModelFrames ?? 0)
            }
            try publish(result, final: true)
            return result
        }
        // Keep only complete fixed cores; the tail needs later original audio, not synthetic silence.
        let result = try batch(input: input, ranges: ranges, through: position, checkpoint: false,
                               tailClosed: false, waiting: true)
        try publish(result, final: true)
        return result
    }

    private func publishArchiveAnalysis(_ result: SpeechAnalysisBatch, input: SpeechInputSet,
                                         channel: SpeechAnalysisChannel, recorder: SpeechDiagnosticRecorder) throws {
        if result.windows.isEmpty {
            try channel.send(SpeechAnalysisPage(batch: result, isFinal: true))
            return
        }
        for start in stride(from: 0, to: result.windows.count, by: archiveBatchSize) {
            let end = min(result.windows.count, start + archiveBatchSize)
            let final = end == result.windows.count
            let windows = Array(result.windows[start..<end])
            let through = windows.last!.coreFrames.end
            let coverage = final ? result.analyzedCoverage
                : [try FrameRange(start: input.start, count: through - input.start)]
            let checkpoint = final ? result.checkpoint
                : SpeechCheckpoint(sessionID: input.sessionID, epochID: input.epochID,
                    sourceFrame: through, configurationFingerprint: configurationFingerprint)
            let page = SpeechAnalysisBatch(windows: windows, analyzedCoverage: coverage,
                noSpeechCoverage: try result.noSpeechCoverage.compactMap { quiet in
                    let lower = max(input.start, quiet.start), upper = min(final ? input.end : through, quiet.end)
                    return upper > lower ? try FrameRange(start: lower, count: upper - lower) : nil
                }, checkpoint: checkpoint,
                waitingForMoreAudio: final && result.waitingForMoreAudio)
            try channel.send(SpeechAnalysisPage(batch: page, isFinal: final))
            recorder.value.outputWindowCount += windows.count
            onEvent(.analysisPageReady(windowCount: windows.count))
            if !final { try channel.waitForDemand(recorder: recorder) }
        }
    }

    private func validateBundle(attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder) throws {
        try validationLock.withLock {
            try attempt.checkCancellation()
            guard !validated else { return }
            // Analysis only needs VAD. Validate the ASR when its runtime loads.
            let hash = try speechFileHash(bundle.directory.appendingPathComponent("silero_vad.onnx"),
                attempt: attempt, recorder: recorder, model: true)
            guard hash == bundle.manifest.vadSHA256 else { throw SpeechError.modelHashMismatch("silero_vad.onnx") }
            try SherpaRuntime.validateVersion()
            validated = true
        }
    }

    private func batch(input: SpeechInputSet, ranges: [Range<Int64>], through: Int64,
                       checkpoint: Bool, tailClosed: Bool, waiting: Bool, finalSourceEnd: Int64? = nil,
                       coverageThrough: Int64? = nil, energy: [SpeechEnergyFrame] = [],
                       hasPendingSpeech: Bool = false) throws -> SpeechAnalysisBatch {
        let planner = WindowPlanner(configuration: configuration, fingerprint: configurationFingerprint)
        let windows: [SpeechWindow]
        if continuousArchive {
            // Extend context only into original, already-leased adjacent audio. Cores stay inside the ticket.
            let pad = input.sampleRate == 16_000 ? SpeechConfiguration.archiveContextFrames : 0
            let anchor = max(input.inputs[0].envelope.manifest.frames.start, input.start - pad)
            let end = min(input.inputs.last!.envelope.manifest.frames.end, input.end + pad)
            let planning = try SpeechInputSet(input.inputs, anchor: anchor, through: end)
            let offset = input.start - anchor
            windows = try planner.continuousWindows(ranges: ranges.map { ($0.lowerBound + offset)..<($0.upperBound + offset) },
                input: planning, availableThrough: through + offset, tailClosed: tailClosed, startAt: offset,
                energy: energy.map { SpeechEnergyFrame(start: $0.start + offset, rms: $0.rms) },
                hasPendingSpeech: hasPendingSpeech)
        } else {
            windows = try planner.windows(ranges: ranges, input: input, availableThrough: through, tailClosed: tailClosed)
        }
        // A closed epoch may leave less than one 16 kHz sample after rational resampling.
        let sourceEnd = finalSourceEnd ?? input.sourceFrame(forModelFrame: coverageThrough ?? through)
        let coverage = checkpoint && sourceEnd > input.start ? [try FrameRange(start: input.start, count: sourceEnd - input.start)] : []
        let noSpeech = try coverage.flatMap { try WindowPlanner.subtract(windows.map(\.coreFrames), from: $0) }
        let resume = checkpoint ? SpeechCheckpoint(sessionID: input.sessionID, epochID: input.epochID,
                                                   sourceFrame: sourceEnd, configurationFingerprint: configurationFingerprint) : nil
        return SpeechAnalysisBatch(windows: windows, analyzedCoverage: coverage, noSpeechCoverage: noSpeech,
                                   checkpoint: resume, waitingForMoreAudio: waiting)
    }
}
