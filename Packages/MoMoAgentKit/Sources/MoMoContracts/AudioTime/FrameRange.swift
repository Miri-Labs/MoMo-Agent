import Foundation

public enum ContractError: Error, Equatable, Sendable {
    case invalidField(String)
    case unsupportedVersion(Int)
    case manifestTooLarge
    case hashMismatch
}

/// Half-open range in the original capture epoch's frame timebase.
public struct FrameRange: Codable, Hashable, Sendable {
    public let start: Int64
    public let count: Int64
    public var end: Int64 { start + count }

    public init(start: Int64, count: Int64) throws {
        guard start >= 0, count > 0, !start.addingReportingOverflow(count).overflow else {
            throw ContractError.invalidField("frame_range")
        }
        self.start = start
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case start, count }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: values.decode(Int64.self, forKey: .start),
                      count: values.decode(Int64.self, forKey: .count))
    }

    public func contains(_ other: FrameRange) -> Bool {
        start <= other.start && end >= other.end
    }

    public static func union(_ ranges: [FrameRange]) throws -> [FrameRange] {
        var result: [FrameRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, range.start <= previous.end {
                result[result.count - 1] = try FrameRange(
                    start: previous.start, count: max(previous.end, range.end) - previous.start
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}
