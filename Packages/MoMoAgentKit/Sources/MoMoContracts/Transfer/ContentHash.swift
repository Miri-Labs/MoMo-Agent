import CryptoKit
import Foundation

public enum ContentHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while true {
                let count = stream.read(base, maxLength: rawBuffer.count)
                guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
                if count == 0 { break }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: rawBuffer[..<count]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum WireJSON {
    private static let dates = WireDates()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            guard milliseconds.isFinite else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Invalid timestamp"))
            }
            // Keep old whole-second projections byte-stable while preserving new millisecond anchors.
            var value = encoder.singleValueContainer()
            try value.encode(dates.string(from: Date(timeIntervalSince1970: milliseconds / 1_000),
                fractional: milliseconds.truncatingRemainder(dividingBy: 1_000) != 0))
        }
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            // Existing manifests keep their original bytes and whole-second timestamps.
            guard let date = dates.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO 8601 timestamp")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

/// Foundation formatters are mutable and not Sendable. Only this lock accesses them;
/// encoders/decoders remain local to each operation, with the original wire format.
private final class WireDates: @unchecked Sendable {
    private let lock = NSLock()
    private let whole = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let parser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init() {
        whole.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func string(from date: Date, fractional includeFraction: Bool) -> String {
        lock.withLock { (includeFraction ? fractional : whole).string(from: date) }
    }

    func date(from text: String) -> Date? {
        // App-written anchors dominate archive reads; avoid ICU parsing and its shared lock.
        if (text.utf8.count == 20 || text.utf8.count == 24), text.hasSuffix("Z"),
           let date = try? parser.parse(text) {
            // Match legacy NSDate's Unix-epoch arithmetic exactly; cached source IDs compare Dates.
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }
        return lock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
    }
}
