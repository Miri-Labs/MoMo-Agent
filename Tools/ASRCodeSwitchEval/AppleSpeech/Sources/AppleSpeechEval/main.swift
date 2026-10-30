// Apple on-device ASR (SpeechAnalyzer + SpeechTranscriber, macOS 26) on the code-switching corpora.
//
// Build and run from the repository root:
//   swift build -c release --package-path Tools/ASRCodeSwitchEval/AppleSpeech
//   B=Tools/ASRCodeSwitchEval/AppleSpeech/.build/release/AppleSpeechEval
//   $B locales                                   # supported / installed locales, asset status
//   $B install --locale zh-CN                    # AssetInventory download if not yet installed
//   $B run --locale zh-CN --corpus CORPUS_DIR --output NEW_DIR [--subsets a,b] [--resume]
//
// Each utterance gets a fresh SpeechTranscriber + SpeechAnalyzer (preset .transcription, final results
// only) fed from the WAV file; the model stays loaded between files (modelRetention .processLifetime).
// SpeechTranscriber always runs on device; the only network use is the optional asset download.
// Output: OUTPUT/hypotheses.jsonl (one row per utterance, appended and flushed) and OUTPUT/run.json.

import AVFoundation
import Darwin
import Foundation
import Speech

struct Item: Decodable {
    let uid: String
    let subset: String
    let seconds: Double
    let audio: String
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func peakRSSBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)  // bytes on macOS
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func status(_ value: AssetInventory.Status) -> String {
    switch value {
    case .unsupported: return "unsupported"
    case .supported: return "supported (not installed)"
    case .downloading: return "downloading"
    case .installed: return "installed"
    @unknown default: return "unknown"
    }
}

func resolveLocale(_ identifier: String) async throws -> Locale {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
        throw Failure(description: "SpeechTranscriber does not support \(identifier)")
    }
    return locale
}

func transcribe(_ url: URL, locale: Locale) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    let collector = Task { () -> [String] in
        var parts: [String] = []
        for try await result in transcriber.results where result.isFinal {
            parts.append(String(result.text.characters))
        }
        return parts
    }
    let file = try AVAudioFile(forReading: url)
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collector.value.joined(separator: " ")
}

func listLocales() async {
    let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
    print("supportedLocales (\(supported.count)): \(supported.joined(separator: " "))")
    print("installedLocales (\(installed.count)): \(installed.joined(separator: " "))")
    for identifier in ["zh-CN", "en-US", "zh-HK", "zh-TW", "yue-CN"] {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
            let value = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
            print("\(identifier) -> \(locale.identifier): \(status(value))")
        } else {
            print("\(identifier): not supported")
        }
    }
}

func install(_ identifier: String) async throws {
    let locale = try await resolveLocale(identifier)
    let module = SpeechTranscriber(locale: locale, preset: .transcription)
    log("\(locale.identifier) before: \(status(await AssetInventory.status(forModules: [module])))")
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        log("downloading assets for \(locale.identifier) ...")
        try await request.downloadAndInstall()
    }
    log("\(locale.identifier) after: \(status(await AssetInventory.status(forModules: [module])))")
}

func run(_ args: [String]) async throws {
    guard let identifier = option("--locale", in: args), let corpusPath = option("--corpus", in: args),
          let outputPath = option("--output", in: args) else {
        throw Failure(description: "run needs --locale, --corpus and --output")
    }
    let resume = args.contains("--resume")
    let subsets = option("--subsets", in: args).map { Set($0.split(separator: ",").map(String.init)) }
    let corpus = URL(fileURLWithPath: corpusPath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: output.path) && !resume {
        throw Failure(description: "Output directory must not exist: \(output.path)")
    }
    let decoder = JSONDecoder()
    var items = try String(contentsOf: corpus.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try decoder.decode(Item.self, from: Data($0.utf8)) }
    if let subsets { items = items.filter { subsets.contains($0.subset) } }
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    let hypotheses = output.appendingPathComponent("hypotheses.jsonl")
    var done: [String: [String: Any]] = [:]
    if resume, let text = try? String(contentsOf: hypotheses, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            if let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let uid = row["uid"] as? String { done[uid] = row }
        }
    }
    let seconds = Dictionary(uniqueKeysWithValues: items.map { ($0.uid, $0.seconds) })
    var totalAudio = done.keys.compactMap { seconds[$0] }.reduce(0, +)
    var totalDecode = done.filter { seconds[$0.key] != nil }.compactMap { $0.value["decodeSeconds"] as? Double }.reduce(0, +)
    var errors = done.filter { seconds[$0.key] != nil && ($0.value["status"] as? String) != "completed" }.count

    let rssBeforeLoad = peakRSSBytes()
    var started = Date()
    let locale = try await resolveLocale(identifier)
    let module = SpeechTranscriber(locale: locale, preset: .transcription)
    let assetStatus = status(await AssetInventory.status(forModules: [module]))
    guard assetStatus == "installed" else {
        throw Failure(description: "Assets for \(locale.identifier) are \(assetStatus); run `install` first")
    }
    let loadSeconds = Date().timeIntervalSince(started)
    // One warm-up decode on the first utterance (loads the model); excluded from the RTF.
    started = Date()
    _ = try await transcribe(corpus.appendingPathComponent(items[0].audio), locale: locale)
    let warmupSeconds = Date().timeIntervalSince(started)

    if !fileManager.fileExists(atPath: hypotheses.path) { fileManager.createFile(atPath: hypotheses.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: hypotheses)
    try handle.seekToEnd()
    for (index, item) in items.enumerated() where done[item.uid] == nil {
        var row: [String: Any] = ["uid": item.uid, "subset": item.subset, "lang": locale.identifier]
        started = Date()
        do {
            row["text"] = try await transcribe(corpus.appendingPathComponent(item.audio), locale: locale)
            row["status"] = "completed"
        } catch {
            errors += 1
            row["text"] = ""
            row["status"] = "error"
            row["error"] = String(describing: error)
        }
        let elapsed = Date().timeIntervalSince(started)
        row["decodeSeconds"] = elapsed
        totalDecode += elapsed
        totalAudio += item.seconds
        var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
        if index % 100 == 0 { log("\(index)/\(items.count) rtf=\(totalDecode / max(totalAudio, 1e-9))") }
    }
    try handle.close()

    let process = ProcessInfo.processInfo
    let summary: [String: Any] = [
        "model": option("--name", in: args) ?? "apple-speechtranscriber-\(identifier.lowercased())",
        "settings": ["locale": locale.identifier, "requestedLocale": identifier, "preset": "transcription",
                     "results": "final only, segments joined with a space",
                     "modelRetention": "processLifetime", "assetStatus": assetStatus],
        "provider": "Apple Speech framework (on-device)", "os": process.operatingSystemVersionString,
        "utterances": items.count, "resumedUtterances": done.count, "subsets": (subsets.map { Array($0).sorted() } ?? []),
        "errors": errors, "audioSeconds": totalAudio, "decodeSeconds": totalDecode,
        "rtf": totalDecode / totalAudio, "loadSeconds": loadSeconds, "warmupSeconds": warmupSeconds,
        "peakRSSBytesBeforeLoad": rssBeforeLoad, "peakRSSBytes": peakRSSBytes(),
        "peakRSSNote": "client process only; inference runs in a system daemon (see run log for its RSS)",
    ]
    let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("run.json"))
    print(String(decoding: json, as: UTF8.self))
}

@main
enum AppleSpeechEval {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "locales": await listLocales()
            case "install": try await install(option("--locale", in: args) ?? "zh-CN")
            case "run": try await run(args)
            default: throw Failure(description: "usage: AppleSpeechEval locales | install --locale L | run --locale L --corpus D --output D [--subsets a,b] [--resume] [--name N]")
            }
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }
}
