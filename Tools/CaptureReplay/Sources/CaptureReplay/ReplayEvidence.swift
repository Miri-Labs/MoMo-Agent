import Darwin
import Foundation
import Synchronization
import MoMoContracts

struct ReplayPlan: Encodable {
    let runID = UUID()
    let sessionID = UUID()
    let epochID = UUID()
    let sourceDeviceID = UUID()
    let receiverDeviceID = UUID()
    let sourceKind = "fixture"
    let processID = ProcessInfo.processInfo.processIdentifier
    let generator = "xorshift64-seed-0x9E3779B97F4A7C15-int16-v1"
    let durationSeconds: Double
    let plannedFrames: Int64
    let sampleRate: Int64
    let inputBlockFrames: Int
    let segmentFrames: Int64
    let requestedSpeed: Double
    let mode: String
    let codec: ReplayCodec
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    init(_ options: ReplayOptions) {
        durationSeconds = options.duration; plannedFrames = options.plannedFrames
        sampleRate = ReplayOptions.sampleRate; inputBlockFrames = ReplayOptions.blockFrames
        segmentFrames = ReplayOptions.segmentFrames; requestedSpeed = options.speed
        mode = options.speed == 1 ? "realtime" : "accelerated"; codec = options.codec
    }
}

struct ReplayReport: Encodable {
    let runID: UUID
    let sourceKind = "fixture"
    let evidenceLayer = "paced-software-file-sqlite"
    var status = "running"
    var startedAt = Date()
    var finishedAt: Date?
    var terminationSignal: Int32?
    var failure: String?
    let plannedFrames: Int64
    let requestedPacingSeconds: Double
    var generatedFrames: Int64 = 0
    var generatedPCMSHA256: String?
    var appendedPCMSHA256: String?
    var reopenedPCMSHA256: String?
    var appendedFrames: Int64 = 0
    var sealedFrames: Int64 = 0
    var receivedFrames: Int64 = 0
    var confirmedFrames: Int64 = 0
    var requestedButNotGeneratedFrames: Int64 = 0
    var generatedButNotAppendedFrames: Int64 = 0
    var appendedButNotSealedFrames: Int64 = 0
    var sealedButNotReceivedFrames: Int64 = 0
    var sealedChunks = 0
    var receivedChunks = 0
    var verifiedAfterReopenChunks = 0
    var finalVerificationComplete = false
    var pendingWatchChunks: Int?
    var pendingInboxFiles: Int?
    var receivedRanges: [FrameRange] = []
    var missingRequestedRanges: [FrameRange] = []
    var uncoveredRequestedFrames: Int64?
    var encodedBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var inputBlocks = 0
    var maximumInputBlockFrames = 0
    var pacingWaitSeconds: Double = 0
    var maximumPacingLatenessSeconds: Double = 0
    var totalPacingLatenessSeconds: Double = 0
    var blocksMoreThanOneBlockLate = 0
    var encodingSeconds: Double = 0
    var persistenceAndDeliverySeconds: Double = 0
    var inputElapsedSeconds: Double = 0
    var totalElapsedSeconds: Double = 0
    var achievedInputSpeed: Double?
    let notExecuted = ["Watch microphone and background capture", "WatchConnectivity", "iPhone runtime and background budget",
        "VAD/ASR and semantic quality", "Agent and model API", "independent real-time microphone producer", "forced process-kill recovery"]

    init(plan: ReplayPlan) {
        runID = plan.runID; plannedFrames = plan.plannedFrames
        requestedPacingSeconds = plan.durationSeconds / plan.requestedSpeed
    }
    mutating func updateMissingCounts() {
        requestedButNotGeneratedFrames = max(0, plannedFrames - generatedFrames)
        generatedButNotAppendedFrames = max(0, generatedFrames - appendedFrames)
        appendedButNotSealedFrames = max(0, appendedFrames - sealedFrames)
        sealedButNotReceivedFrames = max(0, sealedFrames - receivedFrames)
        achievedInputSpeed = inputElapsedSeconds > 0 ? Double(appendedFrames) / 16_000 / inputElapsedSeconds : nil
    }
}

struct ReplayChunkEvent: Encodable {
    let stage: String
    let timestamp = Date()
    let elapsedSeconds: Double
    let sequence: Int64
    let chunkID: UUID
    let frames: FrameRange
    let decodedFrameCount: Int64
    let audioSHA256: String
    let manifestSHA256: String
    let byteCount: Int64
    let requestedBoundarySeconds: Double
    init(stage: String, envelope: ManifestEnvelope, elapsedSeconds: Double, speed: Double) {
        self.stage = stage; self.elapsedSeconds = elapsedSeconds
        let m = envelope.manifest
        sequence = m.sequence; chunkID = m.chunkID; frames = m.frames; decodedFrameCount = m.decodedFrameCount
        audioSHA256 = m.audioSHA256; manifestSHA256 = envelope.manifestSHA256; byteCount = m.byteCount
        requestedBoundarySeconds = Double(m.frames.end) / m.timebaseHz / speed
    }
}

struct ReplayResourceSample: Encodable {
    let timestamp = Date()
    let elapsedSeconds: Double
    let appendedFrames: Int64
    let residentBytes: UInt64
    let peakResidentBytes: Int64
    let freeDiskBytes: Int64
    let thermalState: Int

    static func read(root: URL, elapsedSeconds: Double, appendedFrames: Int64) throws -> Self {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        try CaptureReplay.require(result == KERN_SUCCESS, "Process memory measurement failed")
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        return Self(elapsedSeconds: elapsedSeconds, appendedFrames: appendedFrames, residentBytes: info.resident_size,
            peakResidentBytes: Int64(usage.ru_maxrss), freeDiskBytes: try ReplayEvidence.freeDisk(root),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }
}

final class ReplayStopFlag: Sendable {
    private let signal = Mutex<Int32?>(nil)
    var receivedSignal: Int32? { signal.withLock { $0 } }
    func request(_ value: Int32) { signal.withLock { if $0 == nil { $0 = value } } }
}

enum ReplayEvidence {
    static let diskReserve: Int64 = 2 * 1024 * 1024 * 1024
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try WireJSON.encode(value).write(to: url, options: .atomic)
    }
    static func append<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try WireJSON.encode(value) + Data([10])
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .withoutOverwriting) }
        let file = try FileHandle(forWritingTo: url)
        do { try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { let original = error; try file.close(); throw original }
    }
    static func freeDisk(_ root: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let number = attributes[.systemFreeSize] as? NSNumber else {
            throw VerificationFailure(description: "Free disk capacity is unavailable")
        }
        return number.int64Value
    }
    static func requireDisk(_ root: URL, remainingFrames: Int64) throws {
        // PCM-sized retained output, four transient one-minute copies, and 128 MiB for SQLite/evidence.
        // This conservative estimate is a preflight, not a filesystem reservation.
        let additional = remainingFrames * 2 + ReplayOptions.segmentFrames * 2 * 4 + 128 * 1024 * 1024
        let available = try freeDisk(root)
        try CaptureReplay.require(available >= additional + diskReserve,
            "Insufficient free disk: available=\(available), additionalEstimate=\(additional), reserve=\(diskReserve). Evidence was retained.")
    }
}

extension Duration {
    var replaySeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
