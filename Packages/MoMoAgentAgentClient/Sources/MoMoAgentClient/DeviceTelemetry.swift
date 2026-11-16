import Foundation

public struct DeviceTelemetrySnapshot: Codable, Equatable, Sendable {
    public struct AudioRoute: Codable, Equatable, Sendable {
        public let portType: String
        public let portName: String

        public init(portType: String, portName: String) {
            self.portType = portType
            self.portName = portName
        }
    }

    public struct PhoneTelemetry: Codable, Equatable, Sendable {
        public let batteryLevel: Double?
        public let batteryState: String
        public let lowPowerMode: Bool
        public let thermalState: Int
        public let freeStorageBytes: Int64?
        public let audioRoute: AudioRoute?

        public init(
            batteryLevel: Double?,
            batteryState: String,
            lowPowerMode: Bool,
            thermalState: Int,
            freeStorageBytes: Int64? = nil,
            audioRoute: AudioRoute? = nil
        ) {
            self.batteryLevel = batteryLevel
            self.batteryState = batteryState
            self.lowPowerMode = lowPowerMode
            self.thermalState = thermalState
            self.freeStorageBytes = freeStorageBytes
            self.audioRoute = audioRoute
        }
    }

    public struct WatchTelemetry: Codable, Equatable, Sendable {
        public let deviceId: String
        public let sampledAt: Double
        public let activity: String
        public let pendingChunkCount: Int
        public let pendingBytes: Int64
        public let batteryLevel: Double?
        public let batteryState: String
        public let lowPowerMode: Bool
        public let thermalState: Int
        public let freeStorageBytes: Int64?

        public init(
            deviceId: String,
            sampledAt: Double,
            activity: String,
            pendingChunkCount: Int,
            pendingBytes: Int64,
            batteryLevel: Double? = nil,
            batteryState: String = "unknown",
            lowPowerMode: Bool = false,
            thermalState: Int = 0,
            freeStorageBytes: Int64? = nil
        ) {
            self.deviceId = deviceId
            self.sampledAt = sampledAt
            self.activity = activity
            self.pendingChunkCount = pendingChunkCount
            self.pendingBytes = pendingBytes
            self.batteryLevel = batteryLevel
            self.batteryState = batteryState
            self.lowPowerMode = lowPowerMode
            self.thermalState = thermalState
            self.freeStorageBytes = freeStorageBytes
        }
    }

    public let deviceId: String
    public let revision: Int64
    public let state: String
    public let observedAt: Double
    public let timezone: String
    public let phone: PhoneTelemetry?
    public let watch: WatchTelemetry?

    public init(
        deviceId: String,
        revision: Int64,
        state: String,
        observedAt: Double,
        timezone: String,
        phone: PhoneTelemetry? = nil,
        watch: WatchTelemetry? = nil
    ) {
        self.deviceId = deviceId
        self.revision = revision
        self.state = state
        self.observedAt = observedAt
        self.timezone = timezone
        self.phone = phone
        self.watch = watch
    }

    public init(
        device: UUID,
        revision: Int64,
        state: String,
        observedAt: Date,
        timezone: String = TimeZone.current.identifier,
        phone: PhoneTelemetry? = nil,
        watch: WatchTelemetry? = nil
    ) {
        self.init(
            deviceId: device.uuidString.lowercased(),
            revision: revision,
            state: state,
            observedAt: observedAt.timeIntervalSince1970,
            timezone: timezone,
            phone: phone,
            watch: watch
        )
    }
}

extension AgentClient {
    public func syncDeviceTelemetry(_ snapshot: DeviceTelemetrySnapshot) async throws {
        struct Receipt: Decodable { let deviceId: String; let revision: Int64 }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request(path: ["v1", "device-telemetry"], method: "POST", body: encoder.encode(snapshot))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let receipt = try decoder.decode(Receipt.self, from: data)
        guard receipt.deviceId == snapshot.deviceId, receipt.revision == snapshot.revision else {
            throw AgentClientError.invalidResponse
        }
    }
}
