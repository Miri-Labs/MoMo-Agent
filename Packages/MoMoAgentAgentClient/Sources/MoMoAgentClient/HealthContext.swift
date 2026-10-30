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
    public let deviceId: String
    public let revision: Int64
    public let state: String
    public let observedAt: Double
    public let windowStart: Double
    public let windowEnd: Double
    public let timezone: String
    public let observations: [Observation]
    public init(device: UUID, revision: Int64, state: String, observedAt: Date, windowStart: Date, timezone: String, observations: [Observation]) {
        deviceId = device.uuidString.lowercased(); self.revision = revision; self.state = state
        self.observedAt = observedAt.timeIntervalSince1970; windowEnd = self.observedAt
        self.windowStart = windowStart.timeIntervalSince1970; self.timezone = timezone; self.observations = observations
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
