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

public enum ReceiptBatchLimits {
    // Leaves >= 9.8 KiB inside the 16 KiB LinkControlBudget so a full 16-item ReconcileResponse always fits alongside one batch.
    public static let maximumItems = 12
    public static let maximumEncodedBytes = ReconciliationLimits.maximumEncodedBytes

    static func deterministicUUID(_ seed: String) throws -> UUID {
        let hex = Array(ContentHash.sha256(Data(seed.utf8)).prefix(32))
        let formatted = "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))"
        guard let id = UUID(uuidString: formatted) else {
            throw ContractError.invalidField("receipt_batch_id")
        }
        return id
    }
}

public struct ReceiptBatch: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let items: [Receipt]

    public init(messageID: UUID? = nil, items: [Receipt]) throws {
        try self.init(messageID: messageID, items: items, validateEncodedSize: true)
    }

    private init(messageID: UUID?, items: [Receipt], validateEncodedSize: Bool) throws {
        guard !items.isEmpty, items.count <= ReceiptBatchLimits.maximumItems else {
            throw ContractError.invalidField("receipt_batch_items")
        }
        let receiver = items[0].receiverDeviceID
        let library = items[0].libraryInstanceID
        var seenChunks: Set<UUID> = []
        for item in items {
            guard item.receiverDeviceID == receiver, item.libraryInstanceID == library,
                  seenChunks.insert(item.chunkID).inserted else {
                throw ContractError.invalidField("receipt_batch_items")
            }
        }
        let resolvedID: UUID
        if let messageID {
            resolvedID = messageID
        } else {
            let seed = "receipt-batch/\(receiver.uuidString)/\(library.uuidString)/" +
                items.map(\.receiptID.uuidString).joined(separator: ",")
            resolvedID = try ReceiptBatchLimits.deterministicUUID(seed)
        }
        self.messageID = resolvedID
        self.items = items
        if validateEncodedSize, try WireJSON.encode(self).count > ReceiptBatchLimits.maximumEncodedBytes {
            throw ContractError.invalidField("receipt_batch_size")
        }
    }

    private enum CodingKeys: String, CodingKey { case messageID, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID),
                      items: c.decode([Receipt].self, forKey: .items),
                      validateEncodedSize: false)
    }
}

public struct ReceiptAppliedBatch: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let items: [ReceiptApplied]

    public init(messageID: UUID? = nil, items: [ReceiptApplied]) throws {
        try self.init(messageID: messageID, items: items, validateEncodedSize: true)
    }

    private init(messageID: UUID?, items: [ReceiptApplied], validateEncodedSize: Bool) throws {
        guard !items.isEmpty, items.count <= ReceiptBatchLimits.maximumItems else {
            throw ContractError.invalidField("receipt_applied_batch_items")
        }
        let receiver = items[0].receipt.receiverDeviceID
        let library = items[0].receipt.libraryInstanceID
        var seenChunks: Set<UUID> = []
        for item in items {
            guard item.receipt.receiverDeviceID == receiver, item.receipt.libraryInstanceID == library,
                  seenChunks.insert(item.receipt.chunkID).inserted else {
                throw ContractError.invalidField("receipt_applied_batch_items")
            }
        }
        let resolvedID: UUID
        if let messageID {
            resolvedID = messageID
        } else {
            let seed = "receipt-applied-batch/\(receiver.uuidString)/\(library.uuidString)/" +
                items.map(\.messageID.uuidString).joined(separator: ",")
            resolvedID = try ReceiptBatchLimits.deterministicUUID(seed)
        }
        self.messageID = resolvedID
        self.items = items
        if validateEncodedSize, try WireJSON.encode(self).count > ReceiptBatchLimits.maximumEncodedBytes {
            throw ContractError.invalidField("receipt_applied_batch_size")
        }
    }

    private enum CodingKeys: String, CodingKey { case messageID, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID),
                      items: c.decode([ReceiptApplied].self, forKey: .items),
                      validateEncodedSize: false)
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
    case receiptBatch(ReceiptBatch)
    case receiptApplied(ReceiptApplied)
    case receiptAppliedBatch(ReceiptAppliedBatch)
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
        case .receiptBatch(let value): value.messageID
        case .receiptApplied(let value): value.messageID
        case .receiptAppliedBatch(let value): value.messageID
        case .deleteSession(let value): value.messageID
        case .deleteApplied(let value): value.messageID
        case .reconcileRequest(let value): value.messageID
        case .reconcileResponse(let value): value.messageID
        }
    }

    public static func packReceipts(_ items: [Receipt]) throws -> ControlMessage {
        if items.count == 1 { return .receipt(items[0]) }
        return .receiptBatch(try ReceiptBatch(items: items))
    }

    public static func packReceiptsApplied(_ items: [ReceiptApplied]) throws -> ControlMessage {
        if items.count == 1 { return .receiptApplied(items[0]) }
        return .receiptAppliedBatch(try ReceiptAppliedBatch(items: items))
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
