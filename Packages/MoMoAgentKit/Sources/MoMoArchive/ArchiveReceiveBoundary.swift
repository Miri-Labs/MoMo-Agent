#if DEBUG && os(macOS)
/// Synchronous observation points for an external process-crash harness. Observers do not change archive state.
public enum ArchiveReceiveBoundary: String, Codable, Sendable {
    case inboxManifestSynced = "J08-b"
    case originalsStoredBeforeCommit = "J08-c"
    case receiveCommitted = "J08-d"
}

extension ArchiveStore {
    public func setReceiveBoundaryObserver(_ observer: (@Sendable (ArchiveReceiveBoundary) -> Void)? = nil) {
        receiveBoundaryObserver = observer
    }
}
#endif
