#if DEBUG && os(macOS)
/// Observes real persistence boundaries without changing their outcome or recovery state.
public enum ArchivePlanBoundary: String, Codable, Sendable {
    case transactionBeforeCommit = "J20-transaction"
    case committedBeforeProjection = "J20-committed"
    case projectionBeforeReady = "J20-projection"
}

extension ArchiveStore {
    public func setPlanBoundaryObserver(_ observer: (@Sendable (ArchivePlanBoundary) -> Void)? = nil) {
        planBoundaryObserver = observer
    }
}
#endif
