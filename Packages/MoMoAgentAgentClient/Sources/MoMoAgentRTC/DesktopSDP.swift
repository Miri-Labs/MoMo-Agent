import Foundation

/// Only the authenticated tailnet endpoint is exchanged. LAN candidates are
/// deliberately stripped; the native socket reaches it through a local UDP bridge.
public enum DesktopSDP {
    public static func endpoint(_ sdp: String) throws -> String {
        guard sdp.utf8.count <= 131072 else { throw DesktopRTCError.invalidSignal }
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=candidate:") {
            let fields = line.split(separator: " ")
            if fields.count >= 8, fields[1] == "1", fields[2].lowercased() == "udp", fields[6] == "typ", fields[7] == "host",
               ipv4(String(fields[4])), let port = UInt16(fields[5]), port > 0 {
                return "\(fields[4]):\(port)"
            }
        }
        throw DesktopRTCError.invalidSignal
    }
    public static func route(_ sdp: String, through endpoint: String) throws -> String {
        let parts = endpoint.split(separator: ":")
        let media = sdp.components(separatedBy: .newlines).filter { $0.hasPrefix("m=") }.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        guard sdp.utf8.count <= 131072, parts.count == 2, ipv4(String(parts[0])), let port = UInt16(parts[1]), port > 0,
              media == ["m=video", "m=application"],
              sdp.contains("a=fingerprint:sha-256 "), sdp.contains("a=group:BUNDLE "), sdp.contains("a=rtcp-mux") else { throw DesktopRTCError.invalidSignal }
        var result: [String] = [], inMedia = false
        func candidate() -> [String] { ["a=candidate:1 1 udp 2130706431 \(parts[0]) \(port) typ host", "a=end-of-candidates"] }
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("a=candidate:") || line == "a=end-of-candidates" || line.hasPrefix("a=remote-candidates:") { continue }
            if line.hasPrefix("m=") {
                if inMedia { result += candidate() }; inMedia = true
            }
            if line.hasPrefix("c=IN IP4 ") { result.append("c=IN IP4 \(parts[0])") }
            else { result.append(line) }
        }
        if inMedia { result += candidate() }
        return result.joined(separator: "\r\n") + "\r\n"
    }
    private static func ipv4(_ string: String) -> Bool {
        let bytes = string.split(separator: ".", omittingEmptySubsequences: false)
        return bytes.count == 4 && bytes.allSatisfy { UInt8($0) != nil }
    }
}

public enum DesktopRTCError: Error, LocalizedError, Sendable {
    case invalidSignal, closed, timeout, unavailable, remote(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidSignal: "电脑连接信息无效。"
        case .closed: "电脑连接已断开。"
        case .timeout: "连接电脑超时，请重试。"
        case .unavailable: "视频通道尚未就绪。"
        case .remote(_, let text): text
        }
    }
}
