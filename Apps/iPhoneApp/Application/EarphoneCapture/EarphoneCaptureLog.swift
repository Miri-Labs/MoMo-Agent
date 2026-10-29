import Foundation

/// Bounded JSON Lines record of earphone switching, kept beside the ledger for diagnosing routes on
/// a real device. It holds port types, timings and error codes; no audio, transcript or device name.
@MainActor
final class EarphoneCaptureLog {
    private static let maximumBytes = 512 * 1024
    private let url: URL
    private let previousURL: URL
    private let formatter = ISO8601DateFormatter()

    init(directory: URL) {
        url = directory.appendingPathComponent("events.jsonl")
        previousURL = directory.appendingPathComponent("events.previous.jsonl")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func record(_ event: String, _ fields: [String: String] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["time"] = formatter.string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let files = FileManager.default
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maximumBytes {
            try? files.removeItem(at: previousURL)
            try? files.moveItem(at: url, to: previousURL)
        }
        // Diagnostics must never stop capture, so a failed write is dropped.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    static func describe(_ error: any Error) -> String {
        let native = error as NSError
        // AVAudioSession codes are four-character codes such as '!int'.
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: native.code >> (8 * (3 - $0))) }
        let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(native.domain) \(native.code)\(fourCC)"
    }
}
