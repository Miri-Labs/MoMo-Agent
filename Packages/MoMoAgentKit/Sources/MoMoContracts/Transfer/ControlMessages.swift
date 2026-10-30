import Foundation

public struct Receipt: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let receiptID: UUID
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public let chunkID: UUID
    public let audioSHA256: String
    public let manifestSHA256: String
    public let representation: RepresentationKind

    public init(messageID: UUID = UUID(), receiptID: UUID = UUID(), receiverDeviceID: UUID,
                libraryInstanceID: UUID, chunkID: UUID, audioSHA256: String,
                manifestSHA256: String, representation: RepresentationKind = .full) throws {
        guard ContentHash.isValid(audioSHA256), ContentHash.isValid(manifestSHA256) else {
            throw ContractError.invalidField("receipt_hash")
        }
        self.messageID = messageID; self.receiptID = receiptID
        self.receiverDeviceID = receiverDeviceID; self.libraryInstanceID = libraryInstanceID
        self.chunkID = chunkID; self.audioSHA256 = audioSHA256
        self.manifestSHA256 = manifestSHA256; self.representation = representation
    }

    public func matches(_ envelope: ManifestEnvelope) -> Bool {
        chunkID == envelope.manifest.chunkID && audioSHA256 == envelope.manifest.audioSHA256
            && manifestSHA256 == envelope.manifestSHA256 && representation == envelope.manifest.representation
    }

    private enum CodingKeys: String, CodingKey {
        case messageID, receiptID, receiverDeviceID, libraryInstanceID, chunkID
        case audioSHA256, manifestSHA256, representation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID),
                      receiptID: c.decode(UUID.self, forKey: .receiptID),
                      receiverDeviceID: c.decode(UUID.self, forKey: .receiverDeviceID),
                      libraryInstanceID: c.decode(UUID.self, forKey: .libraryInstanceID),
                      chunkID: c.decode(UUID.self, forKey: .chunkID),
                      audioSHA256: c.decode(String.self, forKey: .audioSHA256),
                      manifestSHA256: c.decode(String.self, forKey: .manifestSHA256),
                      representation: c.decode(RepresentationKind.self, forKey: .representation))
    }
}

public struct ReceiptApplied: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let receipt: Receipt
    public init(messageID: UUID = UUID(), receipt: Receipt) {
        self.messageID = messageID; self.receipt = receipt
    }
}

public struct DeleteSession: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let deletionID: UUID
    public let sessionID: UUID
    public let generation: Int64
    public let receiverDeviceID: UUID?
    public let libraryInstanceID: UUID?
    public init(messageID: UUID = UUID(), deletionID: UUID = UUID(), sessionID: UUID, generation: Int64,
                receiverDeviceID: UUID? = nil, libraryInstanceID: UUID? = nil) throws {
        guard generation > 0 else { throw ContractError.invalidField("deletion_generation") }
        guard (receiverDeviceID == nil) == (libraryInstanceID == nil) else { throw ContractError.invalidField("deletion_receiver") }
        self.messageID = messageID; self.deletionID = deletionID
        self.sessionID = sessionID; self.generation = generation
        self.receiverDeviceID = receiverDeviceID; self.libraryInstanceID = libraryInstanceID
    }

    /// Only a current-library reconciliation can authorize upgrading an unscoped old payload.
    public func scoped(receiverDeviceID: UUID, libraryInstanceID: UUID) throws -> DeleteSession {
        if let device = self.receiverDeviceID, let library = self.libraryInstanceID {
            guard device == receiverDeviceID, library == libraryInstanceID else { throw ContractError.invalidField("deletion_receiver") }
            return self
        }
        let seed = "delete/\(deletionID.uuidString)/\(sessionID.uuidString)/\(generation)/\(receiverDeviceID.uuidString)/\(libraryInstanceID.uuidString)"
        let hex = Array(ContentHash.sha256(Data(seed.utf8)).prefix(32))
        guard let scopedID = UUID(uuidString: "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))") else {
            throw ContractError.invalidField("deletion_receiver")
        }
        return try DeleteSession(messageID: scopedID, deletionID: deletionID, sessionID: sessionID, generation: generation,
            receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID)
    }

    private enum CodingKeys: String, CodingKey { case messageID, deletionID, sessionID, generation, receiverDeviceID, libraryInstanceID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID),
                      deletionID: c.decode(UUID.self, forKey: .deletionID),
                      sessionID: c.decode(UUID.self, forKey: .sessionID),
                      generation: c.decode(Int64.self, forKey: .generation),
                      receiverDeviceID: c.decodeIfPresent(UUID.self, forKey: .receiverDeviceID),
                      libraryInstanceID: c.decodeIfPresent(UUID.self, forKey: .libraryInstanceID))
    }
}

public enum ControlMessage: Codable, Equatable, Sendable {
    case receiverIdentity(ReceiverIdentity)
    case epochEnded(CaptureEpochEnded)
    case epochInterrupted(CaptureEpochInterrupted)
    case captureMark(CaptureMark)
    case receipt(Receipt)
    case receiptApplied(ReceiptApplied)
    case deleteSession(DeleteSession)
    case deleteApplied(DeleteApplied)
    case reconcileRequest(ReconcileRequest)
    case reconcileResponse(ReconcileResponse)

    public var messageID: UUID {
        switch self {
        case .receiverIdentity(let value): value.messageID
        case .epochEnded(let value): value.messageID
        case .epochInterrupted(let value): value.messageID
        case .captureMark(let value): value.messageID
        case .receipt(let value): value.messageID
        case .receiptApplied(let value): value.messageID
        case .deleteSession(let value): value.messageID
        case .deleteApplied(let value): value.messageID
        case .reconcileRequest(let value): value.messageID
        case .reconcileResponse(let value): value.messageID
        }
    }
}

public struct DeleteApplied: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let deletionID: UUID
    public let deviceID: UUID
    public init(messageID: UUID = UUID(), deletionID: UUID, deviceID: UUID) {
        self.messageID = messageID; self.deletionID = deletionID; self.deviceID = deviceID
    }
}
