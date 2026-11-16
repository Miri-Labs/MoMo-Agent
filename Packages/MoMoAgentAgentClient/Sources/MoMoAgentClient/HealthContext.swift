import Foundation

public struct HealthSnapshot: Codable, Equatable, Sendable {
    public struct Observation: Codable, Equatable, Sendable {
        public let metric: String
        public let unit: String
        public let value: Double
        public let start: Double
        public let end: Double
        public let sourceName: String
        public let sourceBundle: String
        public init(metric: String, unit: String, value: Double, start: Date, end: Date, sourceName: String, sourceBundle: String) {
            self.metric = metric; self.unit = unit; self.value = value
            self.start = start.timeIntervalSince1970; self.end = end.timeIntervalSince1970
            self.sourceName = sourceName; self.sourceBundle = sourceBundle
        }
    }

    public struct SleepSession: Codable, Equatable, Sendable {
        public let id: String
        public let start: Double
        public let end: Double
        public let asleepSeconds: Double
        public let inBedSeconds: Double
        public let deepSeconds: Double
        public let coreSeconds: Double
        public let remSeconds: Double
        public let awakeSeconds: Double
        public let sourceName: String
        public let sourceBundle: String

        public init(
            id: String,
            start: Double,
            end: Double,
            asleepSeconds: Double,
            inBedSeconds: Double,
            deepSeconds: Double,
            coreSeconds: Double,
            remSeconds: Double,
            awakeSeconds: Double,
            sourceName: String,
            sourceBundle: String
        ) {
            self.id = id
            self.start = start
            self.end = end
            self.asleepSeconds = asleepSeconds
            self.inBedSeconds = inBedSeconds
            self.deepSeconds = deepSeconds
            self.coreSeconds = coreSeconds
            self.remSeconds = remSeconds
            self.awakeSeconds = awakeSeconds
            self.sourceName = sourceName
            self.sourceBundle = sourceBundle
        }
    }

    public struct WorkoutSummary: Codable, Equatable, Sendable {
        public let id: String
        public let activityType: String
        public let start: Double
        public let end: Double
        public let durationSeconds: Double
        public let activeEnergyKcal: Double?
        public let distanceMeters: Double?
        public let sourceName: String
        public let sourceBundle: String

        public init(
            id: String,
            activityType: String,
            start: Double,
            end: Double,
            durationSeconds: Double,
            activeEnergyKcal: Double? = nil,
            distanceMeters: Double? = nil,
            sourceName: String,
            sourceBundle: String
        ) {
            self.id = id
            self.activityType = activityType
            self.start = start
            self.end = end
            self.durationSeconds = durationSeconds
            self.activeEnergyKcal = activeEnergyKcal
            self.distanceMeters = distanceMeters
            self.sourceName = sourceName
            self.sourceBundle = sourceBundle
        }
    }

    public struct ActivityRingSummary: Codable, Equatable, Sendable {
        public let date: String
        public let activeEnergyKcal: Double
        public let activeEnergyGoalKcal: Double
        public let exerciseMinutes: Double
        public let exerciseGoalMinutes: Double
        public let standHours: Double
        public let standGoalHours: Double

        public init(
            date: String,
            activeEnergyKcal: Double,
            activeEnergyGoalKcal: Double,
            exerciseMinutes: Double,
            exerciseGoalMinutes: Double,
            standHours: Double,
            standGoalHours: Double
        ) {
            self.date = date
            self.activeEnergyKcal = activeEnergyKcal
            self.activeEnergyGoalKcal = activeEnergyGoalKcal
            self.exerciseMinutes = exerciseMinutes
            self.exerciseGoalMinutes = exerciseGoalMinutes
            self.standHours = standHours
            self.standGoalHours = standGoalHours
        }
    }

    public let deviceId: String
    public let revision: Int64
    public let state: String
    public let observedAt: Double
    public let windowStart: Double
    public let windowEnd: Double
    public let timezone: String
    public let observations: [Observation]
    public var sleepSessions: [SleepSession] = []
    public var workouts: [WorkoutSummary] = []
    public var activitySummaries: [ActivityRingSummary] = []

    public init(
        device: UUID,
        revision: Int64,
        state: String,
        observedAt: Date,
        windowStart: Date,
        timezone: String,
        observations: [Observation],
        sleepSessions: [SleepSession] = [],
        workouts: [WorkoutSummary] = [],
        activitySummaries: [ActivityRingSummary] = []
    ) {
        deviceId = device.uuidString.lowercased(); self.revision = revision; self.state = state
        self.observedAt = observedAt.timeIntervalSince1970; windowEnd = self.observedAt
        self.windowStart = windowStart.timeIntervalSince1970; self.timezone = timezone; self.observations = observations
        self.sleepSessions = sleepSessions; self.workouts = workouts; self.activitySummaries = activitySummaries
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, revision, state, observedAt, windowStart, windowEnd, timezone, observations
        case sleepSessions, workouts, activitySummaries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        revision = try c.decode(Int64.self, forKey: .revision)
        state = try c.decode(String.self, forKey: .state)
        observedAt = try c.decode(Double.self, forKey: .observedAt)
        windowStart = try c.decode(Double.self, forKey: .windowStart)
        windowEnd = try c.decode(Double.self, forKey: .windowEnd)
        timezone = try c.decode(String.self, forKey: .timezone)
        observations = try c.decode([Observation].self, forKey: .observations)
        sleepSessions = try c.decodeIfPresent([SleepSession].self, forKey: .sleepSessions) ?? []
        workouts = try c.decodeIfPresent([WorkoutSummary].self, forKey: .workouts) ?? []
        activitySummaries = try c.decodeIfPresent([ActivityRingSummary].self, forKey: .activitySummaries) ?? []
    }
}

extension AgentClient {
    public func syncHealth(_ snapshot: HealthSnapshot) async throws {
        struct Receipt: Decodable { let deviceId: String; let revision: Int64 }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request(path: ["v1", "health"], method: "POST", body: encoder.encode(snapshot))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let receipt = try decoder.decode(Receipt.self, from: data)
        guard receipt.deviceId == snapshot.deviceId, receipt.revision == snapshot.revision else {
            throw AgentClientError.invalidResponse
        }
    }
}
