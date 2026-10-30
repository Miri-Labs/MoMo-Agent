import Foundation

public struct ReceiverIdentity: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public init(messageID: UUID, receiverDeviceID: UUID, libraryInstanceID: UUID) {
        self.messageID = messageID
        self.receiverDeviceID = receiverDeviceID
        self.libraryInstanceID = libraryInstanceID
    }
}

public enum CaptureEndReason: String, Codable, Sendable { case paused, stopped, interrupted, failed }

public struct CaptureEpochEnded: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let sessionID: UUID
    public let epochID: UUID
    public let sourceDeviceID: UUID
    public let endFrame: Int64
    public let reason: CaptureEndReason

    public init(messageID: UUID = UUID(), sessionID: UUID, epochID: UUID,
                sourceDeviceID: UUID, endFrame: Int64, reason: CaptureEndReason) throws {
        guard endFrame >= 0 else { throw ContractError.invalidField("epoch_end_frame") }
        self.messageID = messageID; self.sessionID = sessionID; self.epochID = epochID
        self.sourceDeviceID = sourceDeviceID; self.endFrame = endFrame; self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case messageID, sessionID, epochID, sourceDeviceID, endFrame, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID), sessionID: c.decode(UUID.self, forKey: .sessionID),
                      epochID: c.decode(UUID.self, forKey: .epochID), sourceDeviceID: c.decode(UUID.self, forKey: .sourceDeviceID),
                      endFrame: c.decode(Int64.self, forKey: .endFrame), reason: c.decode(CaptureEndReason.self, forKey: .reason))
    }
}

public struct CaptureMark: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { markID }
    public let messageID: UUID
    public let markID: UUID
    public let sessionID: UUID
    public let epochID: UUID
    public let sourceDeviceID: UUID
    public let sourceFrame: Int64

    public init(messageID: UUID = UUID(), markID: UUID = UUID(), sessionID: UUID, epochID: UUID,
                sourceDeviceID: UUID, sourceFrame: Int64) throws {
        guard sourceFrame >= 0 else { throw ContractError.invalidField("mark_frame") }
        self.messageID = messageID; self.markID = markID
        self.sessionID = sessionID; self.epochID = epochID
        self.sourceDeviceID = sourceDeviceID; self.sourceFrame = sourceFrame
    }

    private enum CodingKeys: String, CodingKey { case messageID, markID, sessionID, epochID, sourceDeviceID, sourceFrame }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID), markID: c.decode(UUID.self, forKey: .markID),
                      sessionID: c.decode(UUID.self, forKey: .sessionID), epochID: c.decode(UUID.self, forKey: .epochID),
                      sourceDeviceID: c.decode(UUID.self, forKey: .sourceDeviceID), sourceFrame: c.decode(Int64.self, forKey: .sourceFrame))
    }
}
