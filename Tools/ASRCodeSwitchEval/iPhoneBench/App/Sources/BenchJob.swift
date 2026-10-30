import AVFoundation
import Foundation
import UIKit

/// One bench run per process launch, so the kernel's peak footprint belongs to exactly one model.
/// Launch arguments: --bench-model KEY --bench-task ascend|real --bench-phase fg|bg --bench-run NAME [--bench-limit N]
struct BenchArguments {
    let model: BenchModel, task: String, phase: String, run: String, limit: Int?

    init?(_ arguments: [String]) {
        var values: [String: String] = [:]
        for (key, value) in zip(arguments, arguments.dropFirst()) where key.hasPrefix("--bench-") {
            values[String(key.dropFirst("--bench-".count))] = value
        }
        guard let key = values["model"], let model = BenchModel.all.first(where: { $0.key == key }),
              let task = values["task"], ["ascend", "real"].contains(task),
              let phase = values["phase"], ["fg", "bg"].contains(phase), let run = values["run"] else { return nil }
        self.model = model; self.task = task; self.phase = phase; self.run = run
        limit = values["limit"].flatMap(Int.init)
    }
}

final class AppStateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var background = false
    var inBackground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return background }
        set { lock.lock(); background = newValue; lock.unlock() }
    }
}

/// Keeps the process running in the background the way an earphone-capture session does (audio mode).
final class BackgroundKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var task: UIBackgroundTaskIdentifier = .invalid

    func start() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            throw BenchError("silence buffer")
        }
        silence.frameLength = silence.frameCapacity
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        task = UIApplication.shared.beginBackgroundTask(withName: "ASR bench") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.task)
            self.task = .invalid
        }
    }
}

final class BenchJob: @unchecked Sendable {
    let arguments: BenchArguments
    let state: AppStateFlag
    let onStatus: @Sendable (String) -> Void
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init(arguments: BenchArguments, state: AppStateFlag, onStatus: @escaping @Sendable (String) -> Void) {
        self.arguments = arguments; self.state = state; self.onStatus = onStatus
    }

    func run() {
        let output = documents.appendingPathComponent("results/\(arguments.run)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try execute(output: output)
        } catch {
            let failure = ["model": arguments.model.key, "task": arguments.task, "phase": arguments.phase,
                           "error": String(describing: error)]
            try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("failed.json"))
            onStatus("FAILED: \(error)")
        }
    }

    private func execute(output: URL) throws {
        let model = arguments.model
        if arguments.phase == "bg" {
            onStatus("waiting for background")
            let deadline = Date().addingTimeInterval(120)
            while !state.inBackground {
                guard Date() < deadline else { throw BenchError("app was not sent to the background within 120 s") }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        let progress = try FileHandle(forWritingTo: {
            let url = output.appendingPathComponent("progress.jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return url
        }())
        let hypotheses = output.appendingPathComponent("hypotheses.jsonl")
        FileManager.default.createFile(atPath: hypotheses.path, contents: nil)
        let hypothesisHandle = try FileHandle(forWritingTo: hypotheses)
        func line(_ handle: FileHandle, _ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }

        let sampler = MemorySampler()
        let baseline = sampler.sample()
        sampler.start()
        let thermalStart = ProcessInfo.processInfo.thermalState
        let cpuStart = cpuSeconds()
        let wallStart = Date()
        func record(_ event: String, _ extra: [String: Any] = [:]) throws {
            let memory = sampler.sample()
            try line(progress, extra.merging(["event": event, "t": Date().timeIntervalSince(wallStart),
                "footprint": memory.footprint, "peakFootprint": memory.peakFootprint, "available": memory.available,
                "background": state.inBackground, "thermal": thermalName(ProcessInfo.processInfo.thermalState)]) { a, _ in a })
        }
        try record("start", ["model": model.key, "task": arguments.task, "phase": arguments.phase])

        let modelDirectory = documents.appendingPathComponent("models/\(model.key)", isDirectory: true)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bench-ort/\(model.key)", isDirectory: true)
        let cacheWarm = FileManager.default.fileExists(atPath: cache.path)
        onStatus("loading \(model.key)")
        let loadStart = Date()
        let recognizer = try makeRecognizer(model, directory: modelDirectory, cache: cache)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        try record("loaded", ["loadSeconds": loadSeconds])

        let data = documents.appendingPathComponent("data/\(arguments.task)", isDirectory: true)
        let audio = try Data(contentsOf: data.appendingPathComponent("audio.f32"), options: .alwaysMapped)
        guard var items = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("index.json")))
            as? [[String: Any]] else { throw BenchError("index.json") }
        if let limit = arguments.limit { items = Array(items.prefix(limit)) }
        func samples(_ item: [String: Any]) -> [Float] {
            var offset = item["offset"] as! Int, count = item["count"] as! Int
            if model.coreOnly, let coreOffset = item["coreOffset"] as? Int, let coreCount = item["coreCount"] as? Int {
                offset += coreOffset; count = coreCount
            }
            return audio.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self)[offset..<(offset + count)])
            }
        }

        var audioSeconds = 0.0, decodeSeconds = 0.0, firstDecodeSeconds: Double?, errors = 0, done = 0
        var backgroundDecodes = 0
        let batchSize = arguments.task == "real" ? model.batchSize : 1
        for start in stride(from: 0, to: items.count, by: batchSize) {
            let batch = Array(items[start..<min(items.count, start + batchSize)])
            let inputs = batch.map(samples)
            let seconds = inputs.reduce(0.0) { $0 + Double($1.count) / 16_000 }
            let began = Date()
            var texts: [String]
            var status = "completed"
            do { texts = try recognizer.recognize(inputs) } catch {
                texts = Array(repeating: "", count: batch.count); status = "error: \(error)"; errors += batch.count
            }
            let elapsed = Date().timeIntervalSince(began)
            if firstDecodeSeconds == nil { firstDecodeSeconds = elapsed } else { audioSeconds += seconds; decodeSeconds += elapsed }
            if state.inBackground { backgroundDecodes += 1 }
            for (item, text) in zip(batch, texts) {
                try line(hypothesisHandle, ["uid": item["uid"]!, "subset": item["subset"] ?? "real", "status": status,
                    "text": text, "lang": "", "decodeSeconds": elapsed / Double(batch.count)])
            }
            done += batch.count
            try record("decoded", ["done": done, "of": items.count, "audioSeconds": seconds, "decodeSeconds": elapsed])
            onStatus("\(model.key) \(arguments.task)/\(arguments.phase): \(done)/\(items.count)")
        }
        sampler.stop()
        let final = sampler.sample()
        let batches = (items.count + batchSize - 1) / batchSize
        let result: [String: Any] = [
            "model": model.key, "task": arguments.task, "phase": arguments.phase, "runtime": recognizer.runtime,
            "threads": Int(benchThreads), "batchSize": batchSize, "coreOnly": model.coreOnly && arguments.task == "real",
            "utterances": items.count, "errors": errors,
            "loadSeconds": loadSeconds, "ortCacheWarm": cacheWarm, "firstDecodeSeconds": firstDecodeSeconds ?? 0,
            "audioSeconds": audioSeconds, "decodeSeconds": decodeSeconds,
            "rtf": audioSeconds > 0 ? decodeSeconds / audioSeconds : 0,
            "rtfNote": "excludes the first decode call (warm-up)",
            "baselineFootprint": baseline.footprint, "peakFootprint": final.peakFootprint,
            "peakRSSBytes": final.peakFootprint, "minimumAvailable": sampler.minimumAvailable,
            "limitEstimate": baseline.footprint + baseline.available,
            "backgroundBatchFraction": Double(backgroundDecodes) / Double(max(1, batches)),
            "cpuSeconds": cpuSeconds() - cpuStart, "wallSeconds": Date().timeIntervalSince(wallStart),
            "thermalStart": thermalName(thermalStart), "thermalMax": thermalName(sampler.maximumThermal),
            "thermalEnd": thermalName(ProcessInfo.processInfo.thermalState),
            "device": deviceModel(), "system": UIDevice.current.systemVersion,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("run.json"))
        try Data().write(to: output.appendingPathComponent("done"))
        onStatus("DONE \(model.key) \(arguments.task)/\(arguments.phase) rtf=\(String(format: "%.3f", decodeSeconds / max(audioSeconds, 1e-9)))")
    }
}

func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
