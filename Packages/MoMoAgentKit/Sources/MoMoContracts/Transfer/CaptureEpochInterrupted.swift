import Foundation

/// Capture stopped without a proven final frame. Neither boundary claims that the tail was saved.
public struct CaptureEpochInterrupted: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let sessionID: UUID
    public let epochID: UUID
    public let sourceDeviceID: UUID
    public let sealedThroughFrame: Int64
    public let lastObservedFrame: Int64
    public let reason: CaptureEndReason

    public init(messageID: UUID = UUID(), sessionID: UUID, epochID: UUID,
                sourceDeviceID: UUID, sealedThroughFrame: Int64, lastObservedFrame: Int64,
                reason: CaptureEndReason) throws {
        guard sealedThroughFrame >= 0, lastObservedFrame >= sealedThroughFrame,
              reason == .interrupted || reason == .failed else {
            throw ContractError.invalidField("epoch_interruption")
        }
        self.messageID = messageID; self.sessionID = sessionID; self.epochID = epochID
        self.sourceDeviceID = sourceDeviceID; self.sealedThroughFrame = sealedThroughFrame
        self.lastObservedFrame = lastObservedFrame; self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case messageID, sessionID, epochID, sourceDeviceID, sealedThroughFrame, lastObservedFrame, reason
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: values.decode(UUID.self, forKey: .messageID),
                      sessionID: values.decode(UUID.self, forKey: .sessionID),
                      epochID: values.decode(UUID.self, forKey: .epochID),
                      sourceDeviceID: values.decode(UUID.self, forKey: .sourceDeviceID),
                      sealedThroughFrame: values.decode(Int64.self, forKey: .sealedThroughFrame),
                      lastObservedFrame: values.decode(Int64.self, forKey: .lastObservedFrame),
                      reason: values.decode(CaptureEndReason.self, forKey: .reason))
    }
}
