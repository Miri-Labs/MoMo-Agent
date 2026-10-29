import Foundation

/// App-owned HTTP service inside Tailscale; never a destination for ordinary networking.
public enum TailnetEndpoint {
    public static let port = 8767

    public static func isAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 && bytes.map(String.init).joined(separator: ".") == host &&
            bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    public static func accepts(_ url: URL) -> Bool {
        url.scheme == "http" && isAddress(url.host ?? "") && url.port == port &&
            url.user == nil && url.password == nil && url.fragment == nil
    }

    public static func isOrigin(_ url: URL) -> Bool {
        accepts(url) && (url.path.isEmpty || url.path == "/") && url.query == nil
    }
}
