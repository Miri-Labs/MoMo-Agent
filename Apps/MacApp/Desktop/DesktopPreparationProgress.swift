import Foundation

enum DesktopPreparationPhase: String, Sendable {
    case python, agent, connection, ready

    var label: String {
        switch self {
        case .python: String(localized: "正在下载运行环境…")
        case .agent: String(localized: "正在下载并安装 Agent 组件…")
        case .connection: String(localized: "正在下载并安装连接组件…")
        case .ready: String(localized: "正在完成安装…")
        }
    }
}

/// Phase markers and uv byte counters update the UI; full logs stay in the diagnostic file.
struct DesktopPreparationEvents {
    private var pending = Data()
    enum Event: Equatable, Sendable { case phase(DesktopPreparationPhase), download(String, Double, Double) }
    private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")
    private static let bytes = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+[-\s]+(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)\s*/\s*(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)\s*$"#)

    mutating func append(_ data: Data) -> [Event] {
        pending.append(data)
        var events: [Event] = []
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let raw = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            let line = Self.ansi.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "MOMO_PREPARE "
            if line.hasPrefix(prefix), let phase = DesktopPreparationPhase(rawValue: String(line.dropFirst(prefix.count))) {
                events.append(.phase(phase))
            } else if let match = Self.bytes.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let source = line as NSString
                let name = source.substring(with: match.range(at: 1))
                guard !name.lowercased().contains("extract") else { continue }
                let units = ["B": 1.0, "KiB": 1024, "MiB": 1048576, "GiB": 1073741824]
                let received = (Double(source.substring(with: match.range(at: 2))) ?? 0) * (units[source.substring(with: match.range(at: 3))] ?? 1)
                let total = (Double(source.substring(with: match.range(at: 4))) ?? 0) * (units[source.substring(with: match.range(at: 5))] ?? 1)
                if total > 0, received >= 0 { events.append(.download(name, min(received, total), total)) }
            }
        }
        // A malformed package log line must not grow memory without a bound.
        if pending.count > 65_536 { pending.removeAll(keepingCapacity: false) }
        return events
    }
}

struct DesktopDownloadProgress {
    private var files: [String: (received: Double, total: Double)] = [:]
    private var samples: [(time: Date, received: Double)] = []
    private(set) var updated = Date()
    var received: Double { files.values.reduce(0) { $0 + $1.received } }
    var total: Double { files.values.reduce(0) { $0 + $1.total } }
    var fraction: Double { total > 0 ? min(1, received / total) : 0 }

    mutating func record(name: String, received: Double, total: Double, now: Date = .now) {
        if let previous = files[name], received < previous.received { samples.removeAll() }
        files[name] = (received, total)
        updated = now
        let count = self.received
        if samples.isEmpty || now.timeIntervalSince(samples.last!.time) >= 0.3 {
            samples.append((now, count))
            samples.removeAll { now.timeIntervalSince($0.time) > 3 }
        }
    }

    func speed(at now: Date) -> Double? {
        guard now.timeIntervalSince(updated) < 3 else { return 0 }
        guard let first = samples.first, let last = samples.last, last.time.timeIntervalSince(first.time) >= 0.3 else { return nil }
        return max(0, (last.received - first.received) / last.time.timeIntervalSince(first.time))
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}
