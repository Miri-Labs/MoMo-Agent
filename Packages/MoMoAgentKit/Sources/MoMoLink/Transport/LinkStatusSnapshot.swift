import Foundation
import MoMoContracts

public enum StatusReceptionOrigin: String, Sendable, Equatable {
    case applicationContextCallback
    case restoredApplicationContext
}

/// A revision gate only. The stores own peer identity, library trust, and observation timestamps.
/// Different streams have no time ordering and never replace each other's watermark.
public struct LinkStatusReceiveState: Sendable {
    private struct Stream: Hashable, Sendable {
        let deviceID: UUID
        let storeInstanceID: UUID
    }
    private struct Watermark: Sendable {
        let revision: Int64
        let hash: String
    }
    private var watermarks: [Stream: Watermark] = [:]

    public init() {}

    /// Seed from a store's already accepted snapshot before replaying the system's retained context.
    public mutating func seed(_ snapshot: StatusSnapshot) throws { _ = try accept(snapshot) }

    @discardableResult public mutating func accept(_ snapshot: StatusSnapshot) throws -> Bool {
        let data = try LinkWireFormat.statusData(snapshot)
        let stream = Stream(deviceID: snapshot.sourceDeviceID, storeInstanceID: snapshot.sourceStoreInstanceID)
        let hash = ContentHash.sha256(data)
        if let known = watermarks[stream] {
            if snapshot.revision < known.revision { return false }
            if snapshot.revision == known.revision {
                guard hash == known.hash else {
                    throw LinkError.conflictingStatus(sourceDeviceID: stream.deviceID,
                        sourceStoreInstanceID: stream.storeInstanceID, revision: snapshot.revision)
                }
                return false
            }
        }
        watermarks[stream] = Watermark(revision: snapshot.revision, hash: hash)
        return true
    }
}

extension LinkWireFormat {
    /// Application budget for encoded snapshot JSON; independent of the durable control queue.
    public static let maximumStatusBytes = 16 * 1_024

    public static func statusMetadata(_ snapshot: StatusSnapshot) throws -> [String: Any] {
        ["protocol_version": 1, "status_snapshot": try statusData(snapshot)]
    }

    public static func statusSnapshot(_ metadata: [String: Any]) throws -> StatusSnapshot {
        guard metadata.count == 2, let version = metadata["protocol_version"] as? Int, version == 1,
              let data = metadata["status_snapshot"] as? Data else { throw LinkError.invalidMetadata }
        guard data.count <= maximumStatusBytes else { throw LinkError.statusSnapshotTooLarge }
        let snapshot = try WireJSON.decode(StatusSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    static func statusData(_ snapshot: StatusSnapshot) throws -> Data {
        try snapshot.validate()
        let data = try WireJSON.encode(snapshot)
        guard data.count <= maximumStatusBytes else { throw LinkError.statusSnapshotTooLarge }
        return data
    }
}
