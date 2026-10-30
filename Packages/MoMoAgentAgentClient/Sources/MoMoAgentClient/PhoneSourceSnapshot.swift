import Foundation

public enum PhoneSourceKind: String, Codable, CaseIterable, Sendable { case visits, calendar, reminders }

/// A bounded, replaceable evidence snapshot. It is not a memory or a command.
public struct PhoneSourceSnapshot: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        public var title: String?
        public var sourceName: String
        public var start: Double?
        public var end: Double?
        public var allDay: Bool?
        public var latitude: Double?
        public var longitude: Double?
        public var accuracy: Double?
        public init(id: String, title: String? = nil, sourceName: String, start: Double? = nil, end: Double? = nil,
                    allDay: Bool? = nil, latitude: Double? = nil, longitude: Double? = nil, accuracy: Double? = nil) {
            self.id = id; self.title = title; self.sourceName = sourceName; self.start = start; self.end = end
            self.allDay = allDay; self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
        }
    }
    public let deviceId: String
    public let kind: PhoneSourceKind
    public let revision: Int64
    public let state: String
    public let observedAt: Double
    public let windowStart: Double
    public let windowEnd: Double
    public let timezone: String
    public let records: [Record]
    public init(device: UUID, kind: PhoneSourceKind, revision: Int64, state: String, observedAt: Date,
                windowStart: Date, windowEnd: Date, records: [Record]) {
        deviceId = device.uuidString.lowercased(); self.kind = kind; self.revision = revision; self.state = state
        self.observedAt = observedAt.timeIntervalSince1970; self.windowStart = windowStart.timeIntervalSince1970
        self.windowEnd = windowEnd.timeIntervalSince1970; timezone = TimeZone.current.identifier; self.records = records
    }
}

extension AgentClient {
    public func syncPhoneSource(_ snapshot: PhoneSourceSnapshot) async throws {
        struct Receipt: Decodable { let deviceId: String; let kind: PhoneSourceKind; let revision: Int64 }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request(path: ["v1", "phone-sources"], method: "POST", body: encoder.encode(snapshot))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let receipt = try decoder.decode(Receipt.self, from: data)
        guard receipt.deviceId == snapshot.deviceId, receipt.kind == snapshot.kind, receipt.revision == snapshot.revision else {
            throw AgentClientError.invalidResponse
        }
    }
}
