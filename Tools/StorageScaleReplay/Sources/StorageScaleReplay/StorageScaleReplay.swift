import Darwin
import Foundation
import MoMoContracts

@main enum StorageScaleReplay {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--worker" {
                try require(arguments.count == 4, "Invalid internal worker arguments")
                guard let batch = Int(arguments[2]) else { throw ScaleFailure(description: "Invalid batch number") }
                try await ScaleScenario.perform(phase: arguments[1], batch: batch,
                    root: URL(fileURLWithPath: arguments[3], isDirectory: true))
            } else if arguments.first == "--cleanup-work" {
                try require(arguments.count == 2, "Usage: StorageScaleReplay --cleanup-work OUTPUT_DIRECTORY")
                try cleanup(URL(fileURLWithPath: arguments[1], isDirectory: true))
            } else {
                try run(arguments)
            }
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        try require(arguments.count == 2 || arguments.count == 4,
            "Usage: StorageScaleReplay --output NEW_DIRECTORY [--hours HOURS_PER_BATCH]")
        try require(arguments[0] == "--output", "Expected --output")
        let hours: Double
        if arguments.count == 4 {
            guard arguments[2] == "--hours", let value = Double(arguments[3]) else {
                throw ScaleFailure(description: "Expected a numeric --hours value")
            }
            hours = value
        } else { hours = 18 }
        try require(hours.isFinite && hours >= 0.05 && hours <= 18 && abs(hours * 60 - (hours * 60).rounded()) < 1e-8,
                    "Hours must produce 3...1080 whole one-minute chunks")
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        try require(!FileManager.default.fileExists(atPath: root.path), "Output directory must not already exist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = UUID(), began = Date(), clock = ContinuousClock.now
        var stages: [ScaleStage] = []
        var failure: String?
        let marker = root.appendingPathComponent("storage-scale-run-id")
        try Data(runID.uuidString.utf8).write(to: marker, options: .withoutOverwriting)
        do {
            // Includes both test suites, overlapping Watch/phone ownership, metadata, and 2 GiB reserve.
            let upper = Int64(hours * 4 * 3600 * 8000) + 128 * 1024 * 1024
            try requireDisk(root, additionalBytes: upper)
            for batches in [1, 3] {
                let scenario = root.appendingPathComponent("work/\(batches)-batch", isDirectory: true)
                try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: true)
                let plan = makePlan(runID: runID, hours: hours, batches: batches)
                try save(plan, to: scenario.appendingPathComponent("plan.json"))
                var phases: [(String, Int)] = []
                for batch in 1...batches {
                    phases += [("generate", batch), ("stage-restart", batch), ("drain", batch)]
                }
                phases += [("final-drain", batches + 1), ("cursor-checkpoint", batches + 1), ("verify", batches + 1)]
                for (phase, batch) in phases {
                    let process = Process()
                    guard let binary = Bundle.main.executableURL else { throw ScaleFailure(description: "Cannot find this executable for restart testing") }
                    process.executableURL = binary
                    process.arguments = ["--worker", phase, String(batch), scenario.path]
                    try process.run()
                    process.waitUntilExit()
                    let evidence = ScaleScenario.stageURL(scenario, phase: phase, batch: batch)
                    if FileManager.default.fileExists(atPath: evidence.path) {
                        stages.append(try WireJSON.decode(ScaleStage.self, from: Data(contentsOf: evidence)))
                        try save(stages, to: root.appendingPathComponent("completed-stages.json"))
                    }
                    try require(process.terminationReason == .exit && process.terminationStatus == 0,
                        "Worker \(batches)-batch/\(batch)-\(phase) failed; its existing database, audio and evidence were retained")
                    try require(stages.last?.phase == phase && stages.last?.batch == batch && stages.last?.failure == nil,
                                "Successful worker did not save its completed evidence")
                }
                // Retain the small input oracle outside work so explicit audio cleanup cannot erase it.
                try FileManager.default.copyItem(at: scenario.appendingPathComponent("inputs.jsonl"),
                    to: root.appendingPathComponent("\(batches)-batch-inputs.jsonl"))
                try FileManager.default.copyItem(at: scenario.appendingPathComponent("plan.json"),
                    to: root.appendingPathComponent("\(batches)-batch-plan.json"))
            }
        } catch { failure = String(describing: error) }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let report = ScaleReport(runID: runID, status: failure == nil ? "passed-software-checks" : "failed",
            profile: hours == 18 ? "18h-and-three-18h-batches" : "smoke", sourceKind: "fixture",
            evidenceLayer: "accelerated-file-sqlite-and-process-restart", buildConfiguration: build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, startedAt: began, finishedAt: Date(),
            wallElapsedSeconds: clock.duration(to: .now).seconds,
            generatedSeconds: stages.reduce(0) { $0 + $1.synthesizedSeconds },
            encodingElapsedSeconds: stages.filter { $0.phase == "generate" }.reduce(0) { $0 + $1.elapsedSeconds },
            receiveAndDrainElapsedSeconds: stages.filter { $0.phase == "drain" || $0.phase == "final-drain" }.reduce(0) { $0 + $1.elapsedSeconds },
            phases: stages, receiveCommitLatency: LatencySummary(stages.flatMap(\.receiveCommitMilliseconds)),
            receiveCommitUnmeasuredCount: stages.reduce(0) { $0 + $1.acceptedChunks - $1.receiveCommitMilliseconds.count },
            thresholds: ["Zero missing immutable chunks, incorrect receipts, duplicate logical records or cursor omissions",
                "Final transfer backlog is zero; each completed source interval is counted once",
                "At most four reserved file transfers; controls at most 32 messages / 16 KiB per page",
                "Memory/latency measurements are observations, without a frozen numeric performance pass threshold"],
            notExecuted: ["Real-time 18-hour elapsed run", "Watch microphone, battery, thermal state or background capture",
                "WCSession scheduling or paired-device transport", "VAD, ASR, transcript generation or acoustic quality",
                "End-to-end transcription RTF and three-day phone-use processing budget", "Agent or remote API",
                "Device memory/performance gates or proof of no growth-related leak"], failure: failure)
        try save(report, to: root.appendingPathComponent("report.json"))
        if let failure { throw ScaleFailure(description: failure) }
        print("PASS SOFTWARE \(report.profile): synthesized \(report.generatedSeconds / 3600) hours, actual \(report.wallElapsedSeconds) seconds. \(root.appendingPathComponent("report.json").path)")
    }

    private static func makePlan(runID: UUID, hours: Double, batches: Int) -> ScalePlan {
        var sessions: [ScaleSession] = []
        let count = Int((hours * 60).rounded())
        for batch in 1...batches {
            var remaining = count, offset = 0
            while remaining > 0 {
                let size = min(20, remaining)
                sessions.append(ScaleSession(id: UUID(), epochID: UUID(), batch: batch, index: sessions.count,
                    chunkCount: size, anchor: Date(timeIntervalSince1970: 1_790_000_000 + Double((batch - 1) * 86_400 + offset * 60))))
                offset += size; remaining -= size
            }
        }
        return ScalePlan(runID: runID, sourceDeviceID: UUID(), receiverDeviceID: UUID(), hoursPerBatch: hours, sessions: sessions, batches: batches)
    }

    private static func cleanup(_ root: URL) throws {
        let marker = try String(contentsOf: root.appendingPathComponent("storage-scale-run-id"), encoding: .utf8)
        let report = try WireJSON.decode(ScaleReport.self, from: Data(contentsOf: root.appendingPathComponent("report.json")))
        try require(report.runID.uuidString == marker && report.status == "passed-software-checks", "Cleanup requires a matching successful report; failed evidence must be inspected manually")
        let work = root.appendingPathComponent("work")
        let value = try work.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        try require(value.isSymbolicLink != true && value.isDirectory == true, "Unexpected work directory")
        try FileManager.default.removeItem(at: work)
        print("Removed generated audio and databases only. report.json and independent input ledgers remain in \(root.path)")
    }
}
