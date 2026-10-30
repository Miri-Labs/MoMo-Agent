import Foundation

public struct DesktopStatus: Codable, Sendable, Equatable {
    public let approved: Bool
    public let screen: Bool
    public let input: Bool
    public let owner: String
    public let active: Bool
    public let epoch: Int
    public let session: String?
    public let input_sequence: Int?
    public let preview_stream: Bool?
}

public struct DesktopFrame: Decodable, Sendable {
    public let jpeg: String
    public let width: Int
    public let height: Int
}

public struct DesktopInput: Encodable, Sendable {
    public let kind: String
    public var x: Double?
    public var y: Double?
    public var to_x: Double?
    public var to_y: Double?
    public var delta: Int?
    public var delta_x: Int?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var button: String?
    public var sequence: Int?
    public var click_count: Int?
    public init(kind: String, x: Double? = nil, y: Double? = nil, to_x: Double? = nil, to_y: Double? = nil,
                delta: Int? = nil, delta_x: Int? = nil, text: String? = nil, key: String? = nil,
                modifiers: [String]? = nil, button: String? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.to_x = to_x; self.to_y = to_y
        self.delta = delta; self.delta_x = delta_x; self.text = text; self.key = key
        self.modifiers = modifiers; self.button = button
    }
}

extension AgentClient {
    public func acknowledgeDesktopFrame(_ picture: DesktopPicture) async throws {
        struct Receipt: Encodable { let stream_id: String; let sequence: Int }
        _ = try await request(path: ["desktop", "v1", "frame-ack"], method: "POST",
            body: JSONEncoder().encode(Receipt(stream_id: picture.streamID, sequence: picture.sequence)))
    }
    public func desktopStatus() async throws -> DesktopStatus {
        try JSONDecoder().decode(DesktopStatus.self, from: await request(path: ["desktop", "v1", "status"]))
    }
    public func requestDesktopAccess() async throws -> DesktopStatus {
        try JSONDecoder().decode(DesktopStatus.self, from: await request(path: ["desktop", "v1", "request"], method: "POST", body: Data("{}".utf8)))
    }
    public func desktopFrame() async throws -> DesktopFrame {
        try JSONDecoder().decode(DesktopFrame.self, from: await request(path: ["desktop", "v1", "frame"]))
    }
    public func desktopControl(_ operation: String, session: String? = nil, requestID: UUID? = nil) async throws -> DesktopStatus {
        guard ["claim", "release", "heartbeat"].contains(operation) else { throw AgentClientError.invalidResponse }
        var payload: [String: String] = [:]
        if let session { payload["session"] = session }
        if let requestID { payload["request_id"] = requestID.uuidString }
        let body = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(DesktopStatus.self, from: await request(path: ["desktop", "v1", operation], method: "POST", body: body))
    }
    public func desktopInput(_ event: DesktopInput, session: String, eventID: UUID = UUID()) async throws {
        struct Payload: Encodable { let session: String; let event: DesktopInput; let event_id: UUID }
        _ = try await request(path: ["desktop", "v1", "input"], method: "POST", body: JSONEncoder().encode(Payload(session: session, event: event, event_id: eventID)))
    }
}
