import Foundation

/// Cumulative per-process counts. Collect on existing events; never add a sampling timer.
public struct CaptureEnergyCounters: Codable, Sendable, Equatable {
    public var progressDeliveries = 0
    public var reconciliationPasses = 0
    public var statusPublications = 0
    public var statusRequests = 0
    public var connectivityGrants = 0
    public var fileCompletions = 0
    public var controlCompletions = 0
    public var transferFailures = 0
    public init() {}
}

/// Local metadata only: no audio, transcript, recording IDs, or device identity.
public struct CaptureEnergySample: Codable, Sendable {
    public let runID: UUID
    public let build: String
    public let recordedAt: Date
    public let uptime: TimeInterval
    public let cpuSeconds: TimeInterval?
    public let batteryLevel: Float?
    public let batteryState: Int
    public let thermalState: Int
    public let presentationSeconds: TimeInterval
    public let activity: CaptureActivity
    public let generation: UInt64
    public let capturedFrames: Int64
    public let tapBlocks: Int64
    public let droppedBlocks: Int64
    public let pendingChunks: Int
    public let outstandingFiles: Int
    public let counters: CaptureEnergyCounters

    public init(runID: UUID, build: String, recordedAt: Date = Date(), uptime: TimeInterval,
                cpuSeconds: TimeInterval?, batteryLevel: Float?, batteryState: Int, thermalState: Int,
                presentationSeconds: TimeInterval, activity: CaptureActivity, generation: UInt64,
                capturedFrames: Int64, tapBlocks: Int64, droppedBlocks: Int64,
                pendingChunks: Int, outstandingFiles: Int, counters: CaptureEnergyCounters) {
        self.runID = runID; self.build = build; self.recordedAt = recordedAt; self.uptime = uptime
        self.cpuSeconds = cpuSeconds; self.batteryLevel = batteryLevel; self.batteryState = batteryState
        self.thermalState = thermalState; self.presentationSeconds = presentationSeconds
        self.activity = activity; self.generation = generation; self.capturedFrames = capturedFrames
        self.tapBlocks = tapBlocks; self.droppedBlocks = droppedBlocks
        self.pendingChunks = pendingChunks; self.outstandingFiles = outstandingFiles; self.counters = counters
    }
}

/// Bounded history survives relaunch. A failed diagnostic write never controls capture or sync.
public actor CaptureEnergyLog {
    public static let interval: TimeInterval = 300
    public static let maximumSamples = 576
    private let url: URL
    private var samples: [CaptureEnergySample]?

    public init(url: URL) { self.url = url }

    public func append(_ sample: CaptureEnergySample) throws {
        if samples == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                let saved = try JSONDecoder().decode([CaptureEnergySample].self, from: Data(contentsOf: url))
                samples = Array(saved.suffix(Self.maximumSamples))
            } else { samples = [] }
        }
        var next = samples ?? []
        next.append(sample)
        if next.count > Self.maximumSamples { next.removeFirst(next.count - Self.maximumSamples) }
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        samples = next
    }
}
