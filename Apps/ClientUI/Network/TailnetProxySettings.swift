import Foundation

struct TailnetProxySettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case system, manual, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "跟随系统")
            case .manual: String(localized: "手动")
            case .direct: String(localized: "不使用代理")
            }
        }
    }
    var mode: Mode = .system
    var address = ""

    func validated() throws -> Self {
        guard mode == .manual else { return Self(mode: mode) }
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else {
            throw ValidationError.invalidAddress
        }
        url.path = ""
        return Self(mode: mode, address: url.string ?? value)
    }

    static func read(from directory: URL) throws -> Self {
        let file = directory.appendingPathComponent("connection-proxy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)).validated()
    }

    func save(to directory: URL) throws {
        let value = try validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("connection-proxy.json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    enum ValidationError: LocalizedError {
        case invalidAddress
        var errorDescription: String? { String(localized: "请输入 HTTP 或 HTTPS 代理地址和端口，不含账号密码。") }
    }
}
