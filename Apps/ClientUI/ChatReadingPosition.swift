import Foundation

struct ChatReadingPosition: Codable, Equatable, Sendable {
    let sessionID: UUID
    let following: Bool
    let top: Double
    let anchorID: String?
    let anchorOffset: Double
    var visibleMessageIDs: [String]? = nil
    var updatedAt = Date()

    var isValid: Bool {
        top.isFinite && top >= 0 && top < 1_000_000_000 && anchorOffset.isFinite
            && abs(anchorOffset) < 1_000_000_000 && (anchorID?.utf8.count ?? 0) <= 2_048
    }
}
