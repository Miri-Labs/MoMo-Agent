import MoMoContracts

public enum RecordingControlKind: String, CaseIterable, Hashable, Sendable {
    case receipt, deletion, capture
}

public struct RecordingControlEntry: Sendable {
    public let sequence: Int64
    public let message: ControlMessage
}
