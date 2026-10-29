import Foundation

/// A replaceable local observation. The recording ledger remains owned by the Watch app.
public struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
    public static let freshnessInterval: TimeInterval = 150
    public let schemaVersion: Int
    public let runtimeID: UUID
    public let generation: UInt64
    public let revision: UInt64
    public let observedAt: Date
    public let sessionID: UUID?
    public let activity: WatchCaptureActivity
    public let capturedDuration: TimeInterval
    public let pendingChunkCount: Int?
    public let lastSampleAt: Date?

    public init(runtimeID: UUID, generation: UInt64, observedAt: Date, sessionID: UUID?,
                activity: WatchCaptureActivity, capturedDuration: TimeInterval,
                pendingChunkCount: Int?, lastSampleAt: Date?, revision: UInt64 = 0) {
        schemaVersion = 1
        self.runtimeID = runtimeID; self.generation = generation; self.observedAt = observedAt
        self.sessionID = sessionID; self.activity = activity; self.capturedDuration = capturedDuration
        self.pendingChunkCount = pendingChunkCount; self.lastSampleAt = lastSampleAt
        self.revision = revision
    }

    public func validate() throws {
        guard schemaVersion == 1, observedAt.timeIntervalSince1970.isFinite,
              capturedDuration.isFinite, capturedDuration >= 0, pendingChunkCount.map({ $0 >= 0 }) ?? true,
              lastSampleAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= observedAt }) ?? true,
              ![.recording, .paused, .interrupted].contains(activity) || sessionID != nil,
              activity != .recording || lastSampleAt != nil else {
            throw WatchWidgetError.invalidSnapshot
        }
    }

    public var expiresAt: Date {
        let reference = activity == .recording ? min(observedAt, lastSampleAt ?? observedAt) : observedAt
        return reference.addingTimeInterval(Self.freshnessInterval)
    }

    public func isFresh(at date: Date) -> Bool {
        date >= observedAt.addingTimeInterval(-5) && date < expiresAt
    }

    public func hasSameCaptureState(as other: Self) -> Bool {
        runtimeID == other.runtimeID && generation == other.generation && sessionID == other.sessionID &&
        activity == other.activity
    }

    public func request(_ action: WatchWidgetAction) -> WatchWidgetRequest {
        WatchWidgetRequest(action: action, runtimeID: runtimeID, generation: generation, sessionID: sessionID)
    }
}

public enum WatchWidgetAction: String, Sendable { case open, start, pause, resume }
public enum WatchWidgetError: Error { case invalidSnapshot, invalidRequest, sharedContainerUnavailable }

/// Explicit actions and an observed generation prevent a stale widget from changing a newer recording.
public struct WatchWidgetRequest: Equatable, Sendable {
    public let action: WatchWidgetAction
    public let runtimeID: UUID?
    public let generation: UInt64?
    public let sessionID: UUID?

    public init(action: WatchWidgetAction = .open, runtimeID: UUID? = nil,
                generation: UInt64? = nil, sessionID: UUID? = nil) {
        self.action = action; self.runtimeID = runtimeID
        self.generation = generation; self.sessionID = sessionID
    }

    public init(url: URL, expectedScheme: String = "momoagent") throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == expectedScheme, parts.host == "capture", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else {
            throw WatchWidgetError.invalidRequest
        }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["action", "runtime", "generation", "session"].contains($0.name) }),
              let value = items.first(where: { $0.name == "action" })?.value,
              let action = WatchWidgetAction(rawValue: value) else { throw WatchWidgetError.invalidRequest }
        func uuid(_ name: String) throws -> UUID? {
            guard let item = items.first(where: { $0.name == name }) else { return nil }
            guard let value = item.value, let id = UUID(uuidString: value) else { throw WatchWidgetError.invalidRequest }
            return id
        }
        let runtime = try uuid("runtime"), session = try uuid("session")
        let generation = items.first(where: { $0.name == "generation" })?.value.flatMap(UInt64.init)
        guard action == .open ? items.count == 1 : runtime != nil && generation != nil,
              action != .pause && action != .resume || session != nil else { throw WatchWidgetError.invalidRequest }
        self.init(action: action, runtimeID: runtime, generation: generation, sessionID: session)
    }

    public var url: URL { url(scheme: "momoagent") }

    public func url(scheme: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = "capture"
        parts.queryItems = [URLQueryItem(name: "action", value: action.rawValue)]
        if action != .open {
            if let runtimeID { parts.queryItems?.append(.init(name: "runtime", value: runtimeID.uuidString)) }
            if let generation { parts.queryItems?.append(.init(name: "generation", value: String(generation))) }
            if let sessionID { parts.queryItems?.append(.init(name: "session", value: sessionID.uuidString)) }
        }
        // All components above are fixed literals, integers or UUIDs.
        return parts.url!
    }

    public func matches(runtimeID: UUID, generation: UInt64, sessionID: UUID?) -> Bool {
        self.runtimeID == runtimeID && self.generation == generation && self.sessionID == sessionID
    }
}
