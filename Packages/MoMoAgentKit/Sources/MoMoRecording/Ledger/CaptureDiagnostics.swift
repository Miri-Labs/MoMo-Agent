import CSQLite
import Foundation
import MoMoContracts

public enum CaptureDiagnosticCode: String, Codable, Sendable {
    case started, paused, stopped, lowSpace, capacityUnavailable
    case systemInterruption, routeChanged, mediaServicesReset, inputOverflow, discontinuousInput, inputStalled
    case startupFailed, writerFailed
    case startRequested, firstSamples, resumeRequested, resumeSucceeded, resumeFailed
    case finalized, cleanupFailed, recoveredInterrupted, encoderStalled, inputEnded
}

public enum CaptureDiagnosticTrigger: String, Codable, Sendable {
    case user, audioSession, engine, watchdog, lifecycle, recovery, worker
}

public enum CaptureDiagnosticErrorFamily: String, Codable, Sendable {
    case permission, capacity, audioSession, audioInput, encoder, filesystem, database, unknown
}

public enum CaptureDiagnosticErrorDomain: String, Codable, Sendable {
    case cocoa, posix, osStatus, avFoundation, sqlite, application, unknown
}

/// Error metadata uses a closed vocabulary; arbitrary domains and userInfo never enter the ledger.
public struct CaptureDiagnosticSafeError: Codable, Equatable, Sendable {
    public let family: CaptureDiagnosticErrorFamily
    public let domain: CaptureDiagnosticErrorDomain
    public let code: Int?

    public init(family: CaptureDiagnosticErrorFamily, domain: CaptureDiagnosticErrorDomain, code: Int? = nil) {
        self.family = family; self.domain = domain; self.code = code
    }

    public init(error: any Error, family: CaptureDiagnosticErrorFamily) {
        self.family = family
        if let database = error as? RecordingDatabaseError {
            domain = .sqlite; code = Int(database.code)
        } else if error is AudioCaptureError || error is CaptureCapacityError || error is AACWriterError || error is RecordingError {
            domain = .application; code = nil
        } else {
            let native = error as NSError
            switch native.domain {
            case NSCocoaErrorDomain: domain = .cocoa
            case NSPOSIXErrorDomain: domain = .posix
            case NSOSStatusErrorDomain: domain = .osStatus
            case "AVFoundationErrorDomain": domain = .avFoundation
            default: domain = .unknown
            }
            code = native.code
        }
    }
}

public struct CaptureDiagnosticTapSnapshot: Codable, Equatable, Sendable {
    public let receivedFrames: Int64
    public let receivedBlocks: Int64
    public let droppedBlocks: Int64
    public let lastTapUptime: TimeInterval?

    public init(receivedFrames: Int64, receivedBlocks: Int64, droppedBlocks: Int64, lastTapUptime: TimeInterval? = nil) {
        self.receivedFrames = receivedFrames; self.receivedBlocks = receivedBlocks
        self.droppedBlocks = droppedBlocks; self.lastTapUptime = lastTapUptime
    }
}

/// Capture this value before asynchronous finalization changes the active epoch or state.
public struct CaptureDiagnosticContext: Codable, Equatable, Sendable {
    public let runID: UUID
    public let sequence: UInt64
    public let sourceBuild: String
    public let uptime: TimeInterval
    public let intent: CaptureIntent
    public let activity: CaptureActivity
    public let generation: UInt64
    public let trigger: CaptureDiagnosticTrigger
    public let routeChangeReason: UInt?
    public let shouldResume: Bool?
    public let builtInMicrophoneSelected: Bool?
    public let tap: CaptureDiagnosticTapSnapshot?
    public let encoderProgressObservedAtUptime: TimeInterval?
    public let finalizationDuration: TimeInterval?
    public let recoveryDuration: TimeInterval?
    public let safeError: CaptureDiagnosticSafeError?

    public init(runID: UUID, sequence: UInt64, sourceBuild: String, uptime: TimeInterval,
                intent: CaptureIntent, activity: CaptureActivity, generation: UInt64, trigger: CaptureDiagnosticTrigger,
                routeChangeReason: UInt? = nil, shouldResume: Bool? = nil, builtInMicrophoneSelected: Bool? = nil, tap: CaptureDiagnosticTapSnapshot? = nil,
                encoderProgressObservedAtUptime: TimeInterval? = nil, finalizationDuration: TimeInterval? = nil,
                recoveryDuration: TimeInterval? = nil, safeError: CaptureDiagnosticSafeError? = nil) {
        self.runID = runID; self.sequence = sequence; self.sourceBuild = sourceBuild; self.uptime = uptime
        self.intent = intent; self.activity = activity; self.generation = generation; self.trigger = trigger
        self.routeChangeReason = routeChangeReason; self.shouldResume = shouldResume
        self.builtInMicrophoneSelected = builtInMicrophoneSelected; self.tap = tap
        self.encoderProgressObservedAtUptime = encoderProgressObservedAtUptime
        self.finalizationDuration = finalizationDuration; self.recoveryDuration = recoveryDuration; self.safeError = safeError
    }
}

/// Local bounded metadata only: never error descriptions, filesystem paths, microphone names or audio.
public struct CaptureDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let code: CaptureDiagnosticCode
    public let sessionID: UUID
    public let epochID: UUID?
    public let observedFrames: Int64
    public let inputSampleRate: Double?
    public let lastSampleUptime: TimeInterval?
    public let capacity: CaptureCapacitySnapshot?
    public let context: CaptureDiagnosticContext?

    public init(code: CaptureDiagnosticCode, sessionID: UUID, epochID: UUID? = nil,
                observedFrames: Int64 = 0, inputSampleRate: Double? = nil,
                lastSampleUptime: TimeInterval? = nil, capacity: CaptureCapacitySnapshot? = nil,
                context: CaptureDiagnosticContext? = nil) {
        id = UUID(); timestamp = Date(); self.code = code; self.sessionID = sessionID; self.epochID = epochID
        self.observedFrames = observedFrames; self.inputSampleRate = inputSampleRate
        self.lastSampleUptime = lastSampleUptime; self.capacity = capacity
        self.context = context
    }
}

extension RecordingStore {
    /// Product retention policy: the most recent 64 capture transitions, independent of recording duration.
    public static let diagnosticLimit = 64

    public func captureCapacityBudget(targetFrames: Int64 = 960_000) throws -> CaptureCapacityBudget {
        let pageSize = try database.rows("PRAGMA page_size") { sqlite3_column_int64($0, 0) }.first ?? 0
        let pageCount = try database.rows("PRAGMA page_count") { sqlite3_column_int64($0, 0) }.first ?? 0
        return try CaptureCapacityBudget(targetFrames: targetFrames, databasePageSize: pageSize, databasePageCount: pageCount)
    }

    public func checkCaptureCapacity(reader: CaptureCapacityReader = .live, targetFrames: Int64 = 960_000,
                                     stage: CaptureCapacityStage = .starting) throws -> CaptureCapacitySnapshot {
        try reader.check(at: rootURL, budget: captureCapacityBudget(targetFrames: targetFrames), stage: stage)
    }

    public func recordDiagnostic(_ diagnostic: CaptureDiagnostic) throws {
        try database.transaction { try insertDiagnostic(diagnostic) }
    }

    /// A capacity stop must require an explicit user retry after restart or a system interruption.
    public func recordCapacityStop(_ diagnostic: CaptureDiagnostic) throws {
        guard diagnostic.code == .lowSpace || diagnostic.code == .capacityUnavailable else {
            throw CaptureCapacityError.invalidBudget
        }
        try database.transaction {
            let stoppedByUser = try intent(sessionID: diagnostic.sessionID) == .stopped
            try saveIntent(stoppedByUser ? .stopped : .paused, sessionID: diagnostic.sessionID)
            try insertDiagnostic(diagnostic)
        }
    }

    public func captureDiagnostics() throws -> [CaptureDiagnostic] {
        try database.rows("SELECT payload FROM capture_diagnostics ORDER BY rowid DESC LIMIT ?", [.integer(Int64(Self.diagnosticLimit))]) {
            try WireJSON.decode(CaptureDiagnostic.self, from: RecordingDatabase.data($0, 0))
        }
    }

    private func insertDiagnostic(_ diagnostic: CaptureDiagnostic) throws {
        try database.execute("INSERT OR IGNORE INTO capture_diagnostics(id,payload) VALUES(?,?)", [.text(diagnostic.id.uuidString), .blob(try WireJSON.encode(diagnostic))])
        try database.execute("DELETE FROM capture_diagnostics WHERE rowid NOT IN (SELECT rowid FROM capture_diagnostics ORDER BY rowid DESC LIMIT ?)", [.integer(Int64(Self.diagnosticLimit))])
    }
}
