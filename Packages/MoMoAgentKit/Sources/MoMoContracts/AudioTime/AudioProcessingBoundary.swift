import Foundation

/// A processing boundary never creates a capture-end event.
public enum AudioProcessingBoundary: Sendable, Equatable {
    case open
    case captureEnd(Int64)
    case receivedSnapshot(Int64)
    case processingRange(Int64)

    public var endFrame: Int64? {
        switch self {
        case .open: nil
        case .captureEnd(let end), .receivedSnapshot(let end), .processingRange(let end): end
        }
    }
}
