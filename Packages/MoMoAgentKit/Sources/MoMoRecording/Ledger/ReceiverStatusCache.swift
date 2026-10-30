import Foundation
import MoMoContracts

public enum ReceiverStatusObservationError: Error { case unexpectedRole, conflictingRevision }

/// Bounded display cache; callers bind it only after their durable receiver identity check succeeds.
public struct ReceiverStatusCache: Sendable {
    public static let maximumSnapshots = 4
    private struct Key: Equatable, Sendable {
        let deviceID: UUID
        let libraryInstanceID: UUID
        init(_ snapshot: StatusSnapshot) {
            deviceID = snapshot.sourceDeviceID; libraryInstanceID = snapshot.sourceStoreInstanceID
        }
        init(deviceID: UUID, libraryInstanceID: UUID) {
            self.deviceID = deviceID; self.libraryInstanceID = libraryInstanceID
        }
    }
    private var snapshots: [StatusSnapshot] = []
    private var bound: Key?
    private var candidate: Key?
    public init() {}
    public var count: Int { snapshots.count }
    public var boundStatus: StatusSnapshot? { snapshots.first { Key($0) == bound } }

    public mutating func bind(deviceID: UUID, libraryInstanceID: UUID) {
        bound = Key(deviceID: deviceID, libraryInstanceID: libraryInstanceID)
        candidate = nil
    }

    public mutating func expectReceiver(deviceID: UUID, libraryInstanceID: UUID) {
        candidate = Key(deviceID: deviceID, libraryInstanceID: libraryInstanceID)
    }

    public mutating func receive(_ snapshot: StatusSnapshot) throws {
        try snapshot.validate()
        guard case .phone = snapshot.payload else { throw ReceiverStatusObservationError.unexpectedRole }
        let key = Key(snapshot)
        if let index = snapshots.firstIndex(where: { Key($0) == key }) {
            let saved = snapshots[index]
            if snapshot.revision < saved.revision { return }
            if snapshot.revision == saved.revision {
                guard snapshot == saved else { throw ReceiverStatusObservationError.conflictingRevision }
                return
            }
            snapshots.remove(at: index)
        }
        snapshots.append(snapshot)
        if snapshots.count > Self.maximumSnapshots,
           let removable = snapshots.firstIndex(where: { Key($0) != bound && Key($0) != candidate }) {
            snapshots.remove(at: removable)
        }
    }
}
