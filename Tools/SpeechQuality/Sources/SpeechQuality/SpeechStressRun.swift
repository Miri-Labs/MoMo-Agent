@preconcurrency import AVFoundation
import Darwin
import Foundation
import os
import MoMoContracts
import MoMoSpeech

/// Offline backlog measurement, never a quality corpus or a device performance acceptance.
enum SpeechStressRun {
    static let fixtureHash = "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"

    struct Options {
        let model: URL, source: URL, output: URL
        let version: String, seconds: Int, dutyFrames: Int, deadline: Int, prepareOnly: Bool
        var totalFrames: Int64 { Int64(seconds) * 16_000 }
        var duty: Double { Double(dutyFrames) / 480_000 }

        init(_ arguments: [String]) throws {
            guard arguments.count >= 9 else { throw StressFailure.invalid("Expected --seconds N --speech-duty R and --prepare-only or --run-prepared") }
            model = URL(fileURLWithPath: arguments[0]); source = URL(fileURLWithPath: arguments[1])
            output = URL(fileURLWithPath: arguments[2]); version = arguments[3]
            var flags: [String: String] = [:], mode: String?
            var index = 4
            while index < arguments.count {
                let key = arguments[index]
                if key == "--prepare-only" || key == "--run-prepared" {
                    guard mode == nil else { throw StressFailure.invalid("Use exactly one execution mode") }
                    mode = key; index += 1
                } else {
                    guard ["--seconds", "--speech-duty", "--deadline-seconds"].contains(key),
                          index + 1 < arguments.count, flags[key] == nil else { throw StressFailure.invalid("Unknown or repeated option") }
                    flags[key] = arguments[index + 1]; index += 2
                }
            }
            guard let duration = Int(flags["--seconds"] ?? ""), (60...7_200).contains(duration), duration % 60 == 0,
                  let ratio = Double(flags["--speech-duty"] ?? ""), ratio.isFinite, ratio > 0, ratio <= 1,
                  let limit = Int(flags["--deadline-seconds"] ?? "900"), (10...3_600).contains(limit),
                  let mode, !version.isEmpty else { throw StressFailure.invalid("Duration/duty/deadline outside bounded diagnostic range") }
            seconds = duration; dutyFrames = Int((ratio * 480_000).rounded()); deadline = limit
            guard dutyFrames >= 16_000 else { throw StressFailure.invalid("Each 30-second cycle needs at least one second of inserted fixture") }
            prepareOnly = mode == "--prepare-only"
        }
    }

    static func run(arguments: [String]) async throws {
        let options = try Options(arguments)
        guard try ContentHash.sha256(fileAt: options.source) == fixtureHash else { throw StressFailure.invalid("Official input hash mismatch") }
        let voice = try SpeechDiagnosticsRun.readVoice(options.source)
        let bundle = try SpeechModelBundle.load(from: options.model)
        let configuration = try SpeechConfiguration()
        if options.prepareOnly {
            try prepare(options, voice: voice, bundle: bundle, configuration: configuration)
            return
        }
        let metadata = try object(Data(contentsOf: options.output.appendingPathComponent("run.json")))
        guard metadata["sourceVersion"] as? String == options.version,
              metadata["sourceSHA256"] as? String == fixtureHash,
              metadata["seconds"] as? Int == options.seconds,
              metadata["speechOnFramesPerCycle"] as? Int == options.dutyFrames,
              metadata["deadlineSeconds"] as? Int == options.deadline,
              !FileManager.default.fileExists(atPath: options.output.appendingPathComponent("operations.jsonl").path) else {
            throw StressFailure.invalid("Prepared metadata changed or workload already started")
        }
        let manifestURL = options.output.appendingPathComponent("inputs/inputs.json")
        let manifests = try WireJSON.decode([ChunkManifest].self, from: Data(contentsOf: manifestURL))
        var position: Int64 = 0
        let inputs = try manifests.map { manifest in
            let url = options.output.appendingPathComponent("inputs/\(manifest.sequence).wav")
            let file = try AVAudioFile(forReading: url)
            guard manifest.frames.start == position, manifest.frames.count <= 960_000,
                  file.length == manifest.frames.count, file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1,
                  try ContentHash.sha256(fileAt: url) == manifest.audioSHA256 else { throw StressFailure.invalid("Prepared file changed") }
            position = manifest.frames.end
            return SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: url)
        }
        guard position == options.totalFrames else { throw StressFailure.invalid("Prepared duration mismatch") }
        // The external runner independently checks all PCM, durations and hashes before this stage.
        try await measure(options, bundle: bundle, configuration: configuration, inputs: inputs)
    }

    private static func prepare(_ options: Options, voice: [Int16], bundle: SpeechModelBundle,
                                configuration: SpeechConfiguration) throws {
        guard !FileManager.default.fileExists(atPath: options.output.path) else { throw StressFailure.invalid("Output must be new") }
        let directory = options.output.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID(), epoch = UUID(), device = UUID()
        var manifests: [ChunkManifest] = []
        for start in stride(from: Int64(0), to: options.totalFrames, by: 960_000) {
            let count = Int(min(960_000, options.totalFrames - start))
            var data = Data(capacity: 44 + count * 2)
            func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
            u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(count * 2))
            for offset in 0..<count {
                let frame = Int(start) + offset
                let sample: Int16 = frame % 480_000 < options.dutyFrames ? voice[frame % voice.count] : 0
                u16(UInt16(bitPattern: sample))
            }
            let sequence = Int64(manifests.count)
            try data.write(to: directory.appendingPathComponent("\(sequence).wav"), options: .withoutOverwriting)
            manifests.append(try ChunkManifest(sessionID: session, epochID: epoch, chunkID: UUID(), sourceDeviceID: device,
                sourceBuild: "speech-stress-v1", sequence: sequence, frames: FrameRange(start: start, count: Int64(count)),
                timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0,
                codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: Int64(count),
                byteCount: Int64(data.count), audioSHA256: ContentHash.sha256(data),
                sealedAt: Date(timeIntervalSince1970: Double(start + Int64(count)) / 16_000), sourceKind: .fixture))
        }
        try WireJSON.encode(manifests).write(to: directory.appendingPathComponent("inputs.json"), options: .atomic)
        try save(["schemaVersion": 1, "sourceVersion": options.version, "sourceSHA256": fixtureHash,
                  "seconds": options.seconds, "speechOnFramesPerCycle": options.dutyFrames, "cycleFrames": 480_000,
                  "injectedFixtureDutyRatio": options.duty, "deadlineSeconds": options.deadline,
                  "configuration": try object(WireJSON.encode(configuration)), "modelManifest": try object(WireJSON.encode(bundle.manifest)),
                  "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                  "scope": "Mac offline backlog; repeated public fixture, periodic inserted silence; not natural conversation, CER, real-time acquisition, iPhone budget, energy or thermal acceptance"],
                 to: options.output.appendingPathComponent("run.json"))
        print("Prepared \(options.seconds)s in \(manifests.count) bounded WAV files; independent verification required before execution.")
    }

    private static func measure(_ options: Options, bundle: SpeechModelBundle, configuration: SpeechConfiguration,
                                inputs: [SpeechAudioInput]) async throws {
        let collector = StressCollector()
        let engine = try SpeechEngine(bundle: bundle, configuration: configuration,
            onDiagnostics: { collector.record($0) }, onEvent: { collector.event($0) })
        let operations = try StressJSONLines(options.output.appendingPathComponent("operations.jsonl"))
        let progress = try StressJSONLines(options.output.appendingPathComponent("progress.jsonl"))
        let rss = try StressRSSSampler(options.output.appendingPathComponent("rss.jsonl"))
        defer { operations.close(); progress.close() }
        let start = ProcessInfo.processInfo.systemUptime
        let attempt = SpeechAttempt()
        let deadline = DispatchWorkItem { attempt.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(options.deadline), execute: deadline)
        defer { deadline.cancel() }
        var cursor: Int64 = 0, completed: Int64 = 0, coreFrames: Int64 = 0, previousCoreEnd: Int64 = 0
        var checkpoint: SpeechCheckpoint?, probe: SpeechWindow?
        var windowIDs = Set<String>(), batchCount = 0, maximumPendingWindows = 0
        var workloadSeconds: Double = 0
        var sequence: SpeechTranscriptionSequence?
        func drain(_ phase: String) throws -> SpeechDiagnostics {
            let value = try collector.take()
            try operations.append(["phase": phase, "elapsedSinceStart": ProcessInfo.processInfo.systemUptime - start,
                                   "diagnostic": try object(WireJSON.encode(value))])
            return value
        }
        func report(_ kind: String, extra: [String: Any] = [:]) throws {
            var value: [String: Any] = ["kind": kind, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                "analysisCheckpointFrames": cursor, "completedThroughFrames": completed,
                "availableBacklogSeconds": Double(options.totalFrames - completed) / 16_000,
                "completedWindows": windowIDs.count, "residentBytes": try StressRSSSampler.residentBytes()]
            value.merge(extra) { _, new in new }; try progress.append(value)
        }
        do {
            try report("start")
            while cursor < options.totalFrames {
                let batch: SpeechAnalysisBatch
                do { batch = try await engine.prepare(inputs: inputs, resume: checkpoint, epochClosed: true, attempt: attempt) }
                catch { _ = try drain("workload"); throw error }
                let preparation = try drain("workload")
                guard preparation.outcome == .completed, let next = batch.checkpoint,
                      next.sourceFrame > cursor, next.sourceFrame <= options.totalFrames, !batch.waitingForMoreAudio else {
                    throw StressFailure.invalid("Closed analysis failed to advance")
                }
                batchCount += 1; maximumPendingWindows = max(maximumPendingWindows, batch.windows.count)
                try report("prepared", extra: ["batch": batchCount, "pendingWindows": batch.windows.count,
                    "nextCheckpointFrames": next.sourceFrame,
                    "analyzedCoverage": try JSONSerialization.jsonObject(with: WireJSON.encode(batch.analyzedCoverage)),
                    "noSpeechCoverage": try JSONSerialization.jsonObject(with: WireJSON.encode(batch.noSpeechCoverage))])
                if let first = batch.windows.first {
                    sequence = try engine.makeTranscriptionSequence(inputs: inputs, anchor: first.analysisAnchor)
                }
                for window in batch.windows {
                    guard !windowIDs.contains(window.id), windowIDs.count < 36_000,
                          window.coreFrames.start >= previousCoreEnd else { throw StressFailure.invalid("Duplicate or overlapping window") }
                    let recognition: SpeechRecognition
                    do {
                        guard let sequence else { throw StressFailure.invalid("Missing sequential reader") }
                        recognition = try await engine.transcribe(window: window, sequence: sequence, attempt: attempt)
                    }
                    catch { _ = try drain("workload"); throw error }
                    let decode = try drain("workload")
                    guard decode.outcome == .completed, recognition.windowID == window.id,
                          recognition.configurationFingerprint == engine.configurationFingerprint else { throw StressFailure.invalid("Recognition identity mismatch") }
                    windowIDs.insert(window.id)
                    previousCoreEnd = window.coreFrames.end; coreFrames += window.coreFrames.count
                    completed = window.coreFrames.end
                    if probe == nil { probe = window }
                    try report("transcribed", extra: ["window": try object(WireJSON.encode(window)),
                        "recognitionUTF8Bytes": recognition.text.utf8.count,
                        "recognitionSHA256": ContentHash.sha256(Data(recognition.text.utf8))])
                }
                if let sequence { await engine.close(sequence) }; sequence = nil
                cursor = next.sourceFrame; completed = cursor; checkpoint = next
                try report("batch_completed")
                print("Processed \(cursor / 16_000)/\(options.seconds)s; \(windowIDs.count) windows")
            }
            workloadSeconds = ProcessInfo.processInfo.systemUptime - start
            guard let probe else { throw StressFailure.invalid("Fixture generated no speech windows") }
            // A separate attempt on the same executor proves real native cancellation and later reuse.
            let cancelledAttempt = SpeechAttempt()
            collector.arm(cancelledAttempt)
            var wasCancelled = false
            do { _ = try await engine.transcribe(window: probe, inputs: SpeechDiagnosticsRun.inputsFor(probe, in: inputs), attempt: cancelledAttempt) }
            catch SpeechError.cancelled { wasCancelled = true }
            catch { _ = try drain("native_cancel_probe"); throw error }
            collector.disarm()
            let cancellation = try drain("native_cancel_probe")
            guard wasCancelled, cancellation.outcome == .cancelled, cancellation.cancellationDuringNativeDecode else {
                throw StressFailure.invalid("Cancellation missed native interval; no latency claim")
            }
            do { _ = try await engine.transcribe(window: probe, inputs: SpeechDiagnosticsRun.inputsFor(probe, in: inputs), attempt: attempt) }
            catch { _ = try drain("reuse_probe"); throw error }
            guard try drain("reuse_probe").outcome == .completed else { throw StressFailure.invalid("Executor did not recover") }
            let memory = try rss.finish()
            try save(["status": "completed", "totalSourceFrames": options.totalFrames, "completedThroughFrames": completed,
                "uniqueCoreFrames": coreFrames, "completedWindows": windowIDs.count, "batches": batchCount,
                "maximumPendingWindows": maximumPendingWindows, "workloadElapsedSeconds": workloadSeconds,
                "totalElapsedSecondsIncludingProbes": ProcessInfo.processInfo.systemUptime - start,
                "sourceSecondsPerWallSecond": Double(options.seconds) / workloadSeconds,
                "rss": memory, "nativeCancellationObserved": true], to: options.output.appendingPathComponent("completion.json"))
        } catch {
            if let sequence { await engine.close(sequence) }
            collector.disarm()
            let memory = (try? rss.finish()) ?? [:]
            try? save(["status": "failed", "error": String(describing: error), "completedThroughFrames": completed,
                "completedWindows": windowIDs.count, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                "deadlineSeconds": options.deadline, "rss": memory], to: options.output.appendingPathComponent("completion.json"))
            throw error
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StressFailure.invalid("Expected JSON object") }
        return object
    }
    static func save(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
}

private enum StressFailure: Error { case invalid(String) }

private final class StressJSONLines: @unchecked Sendable {
    private let file: FileHandle
    init(_ url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        file = try FileHandle(forWritingTo: url)
    }
    func append(_ value: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        line.append(10); try file.write(contentsOf: line)
    }
    func close() { try? file.close() }
}

private final class StressCollector: Sendable {
    private struct State { var value: SpeechDiagnostics?; var overwritten = false; var cancellation: SpeechAttempt?; var work: DispatchWorkItem? }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    func record(_ value: SpeechDiagnostics) { lock.withLock { if $0.value != nil { $0.overwritten = true }; $0.value = value } }
    func take() throws -> SpeechDiagnostics {
        try lock.withLock { state in
            guard let value = state.value, !state.overwritten else { throw StressFailure.invalid("Diagnostic callback count mismatch") }
            state.value = nil; return value
        }
    }
    func arm(_ attempt: SpeechAttempt) { lock.withLock { $0.cancellation = attempt } }
    func disarm() { lock.withLock { $0.work?.cancel(); $0.work = nil; $0.cancellation = nil } }
    func event(_ event: SpeechExecutionEvent) {
        lock.withLock { state in
            switch event {
            case .analysisPageReady: break
            case .nativeDecodeStarted:
                guard let attempt = state.cancellation else { return }
                let work = DispatchWorkItem { attempt.cancel() }; state.work = work
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(10), execute: work)
            case .nativeDecodeReturned: state.work?.cancel(); state.work = nil
            }
        }
    }
}

private final class StressRSSSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MoMoAgent.stress.rss")
    private let timer: DispatchSourceTimer, file: StressJSONLines
    private let start = ProcessInfo.processInfo.systemUptime
    private var count = 0, minimum: UInt64 = .max, maximum: UInt64 = 0, last: UInt64 = 0
    private var failure: Error?
    private var finished = false
    init(_ url: URL) throws {
        file = try StressJSONLines(url); timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.sample() }; timer.resume()
    }
    private func sample() {
        do {
            let bytes = try Self.residentBytes(); count += 1; minimum = min(minimum, bytes); maximum = max(maximum, bytes); last = bytes
            try file.append(["elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "residentBytes": bytes])
        } catch { failure = error }
    }
    func finish() throws -> [String: Any] {
        try queue.sync {
            if !finished { sample(); timer.cancel(); file.close(); finished = true }
            if let failure { throw failure }
            return ["samples": count, "minimumResidentBytes": minimum, "maximumSampledResidentBytes": maximum,
                    "lastResidentBytes": last, "sampleIntervalMilliseconds": 500]
        }
    }
    static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw StressFailure.invalid("Cannot sample process RSS") }
        return UInt64(info.resident_size)
    }
}
