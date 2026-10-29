import Darwin
import Foundation
import MoMoContracts

struct ScaleFailure: Error, CustomStringConvertible { let description: String }

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ScaleFailure(description: message) }
}

struct ScalePlan: Codable {
    let runID: UUID
    let sourceDeviceID: UUID
    let receiverDeviceID: UUID
    let hoursPerBatch: Double
    let sessions: [ScaleSession]
    let batches: Int
    var chunksPerBatch: Int { Int((hoursPerBatch * 60).rounded()) }
}

struct ScaleSession: Codable {
    let id: UUID
    let epochID: UUID
    let batch: Int
    let index: Int
    let chunkCount: Int
    let anchor: Date
}

struct ScaleInput: Codable {
    let chunkID: UUID
    let sessionID: UUID
    let epochID: UUID
    let sequence: Int64
    let frames: FrameRange
    let audioSHA256: String
    let manifestSHA256: String
    let byteCount: Int64
}

struct PageCheckpoint: Codable {
    let sessionIDs: [UUID]
    let nextCursor: String?
}

struct ResourceSample: Codable {
    let residentBytes: UInt64
    let peakResidentBytes: Int64
    let freeDiskBytes: Int64
    let fileCount: Int
    let logicalFileBytes: Int64
    let allocatedFileBytes: Int64
    let databaseAndWALBytes: Int64

    static func read(root: URL) throws -> Self {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        try require(status == KERN_SUCCESS, "Cannot measure process resident memory")
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw ScaleFailure(description: "Cannot enumerate evidence files")
        }
        var files = 0, logical: Int64 = 0, allocated: Int64 = 0, database: Int64 = 0
        for case let url as URL in entries {
            let value = try url.resourceValues(forKeys: keys)
            try require(value.isSymbolicLink != true, "Unexpected symbolic link in generated evidence")
            guard value.isRegularFile == true else { continue }
            files += 1
            let bytes = Int64(value.fileSize ?? 0)
            logical += bytes
            allocated += Int64(value.totalFileAllocatedSize ?? value.fileSize ?? 0)
            if [".sqlite", ".sqlite-wal", ".sqlite-shm"].contains(where: url.lastPathComponent.hasSuffix) { database += bytes }
        }
        return Self(residentBytes: info.resident_size, peakResidentBytes: Int64(usage.ru_maxrss),
            freeDiskBytes: try freeDisk(root), fileCount: files, logicalFileBytes: logical,
            allocatedFileBytes: allocated, databaseAndWALBytes: database)
    }
}

struct ScaleStage: Codable {
    let scenario: String
    let phase: String
    let batch: Int
    let processID: Int32
    var startedAt = Date()
    var elapsedSeconds: Double = 0
    var generatedChunks = 0
    var acceptedChunks = 0
    var duplicateReceives = 0
    var acknowledgedChunks = 0
    var pendingChunks: Int?
    var transferredBytes: Int64 = 0
    var controlMessages = 0
    var controlPages = 0
    var maximumControlPageBytes = 0
    var maximumReservedFiles = 0
    var receiveCommitMilliseconds: [Double] = []
    var resourceSamples: [ResourceSample] = []
    var verifiedSessions = 0
    var checks: [String] = []
    var failure: String?
    var synthesizedSeconds: Double = 0
    var newlyAcknowledgedSeconds: Double = 0
    var pendingSeconds: Double?
}

struct ScaleReport: Codable {
    let runID: UUID
    let status: String
    let profile: String
    let sourceKind: String
    let evidenceLayer: String
    let buildConfiguration: String
    let operatingSystem: String
    let startedAt: Date
    let finishedAt: Date
    let wallElapsedSeconds: Double
    let generatedSeconds: Double
    let encodingElapsedSeconds: Double
    let receiveAndDrainElapsedSeconds: Double
    let phases: [ScaleStage]
    let receiveCommitLatency: LatencySummary
    let receiveCommitUnmeasuredCount: Int
    let thresholds: [String]
    let notExecuted: [String]
    let failure: String?
}

struct LatencySummary: Codable {
    let count: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maximumMilliseconds: Double?
    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        p50Milliseconds = sorted.isEmpty ? nil : sorted[Int(Double(sorted.count - 1) * 0.50)]
        p95Milliseconds = sorted.isEmpty ? nil : sorted[Int(Double(sorted.count - 1) * 0.95)]
        maximumMilliseconds = sorted.last
    }
}

let reserveBytes: Int64 = 2 * 1024 * 1024 * 1024

func freeDisk(_ root: URL) throws -> Int64 {
    let values = try FileManager.default.attributesOfFileSystem(forPath: root.path)
    guard let free = values[.systemFreeSize] as? NSNumber else { throw ScaleFailure(description: "Free disk capacity is unavailable") }
    return free.int64Value
}

func requireDisk(_ root: URL, additionalBytes: Int64) throws {
    let free = try freeDisk(root)
    try require(free >= additionalBytes + reserveBytes,
        "Insufficient disk: free=\(free), additional upper estimate=\(additionalBytes), required reserve=\(reserveBytes). Existing evidence was retained.")
}

func save<T: Encodable>(_ value: T, to url: URL) throws {
    try WireJSON.encode(value).write(to: url, options: .atomic)
}

func append<T: Encodable>(_ value: T, to url: URL) throws {
    let bytes = try WireJSON.encode(value) + Data([10])
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .withoutOverwriting) }
    let file = try FileHandle(forWritingTo: url)
    do {
        try file.seekToEnd(); try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
    } catch { let original = error; try file.close(); throw original }
}

func inputLedger(_ root: URL) throws -> [ScaleInput] {
    try Data(contentsOf: root.appendingPathComponent("inputs.jsonl")).split(separator: 10).map {
        try WireJSON.decode(ScaleInput.self, from: Data($0))
    }
}
