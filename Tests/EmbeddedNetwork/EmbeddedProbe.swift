import Foundation
import Network
import TailscaleKit
import Darwin

enum Probe {
    static func run(controlURL: String, root: URL) async throws {
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func node(_ name: String) throws -> TailscaleNode {
            try TailscaleNode(config: Configuration(hostName: name, path: root.appendingPathComponent(name).path,
                authKey: nil, controlURL: controlURL, ephemeral: false), logger: nil)
        }
        let server = try node("momo-poc-mac"); try await server.up()
        var phone = try node("momo-poc-phone"); try await phone.up()
        let firstPhoneIP = try await phone.addrs().ip4
        let ip = try await server.addrs().ip4!
        let statusData = try await server.statusJSON()
        let status = try JSONSerialization.jsonObject(with: statusData) as! [String: Any]
        precondition((status["CertDomains"] as? [String] ?? []).isEmpty)
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        precondition(listenFD >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        precondition(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        precondition(Darwin.listen(listenFD, 4) == 0)
        var addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        precondition(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &addressSize) } } == 0)
        try await server.serveLoopbackHTTP(port: Int32(UInt16(bigEndian: address.sin_port)))
        let service = Task.detached {
            for turn in 1...2 {
                let conn = Darwin.accept(listenFD, nil, nil)
                precondition(conn >= 0)
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(conn, &bytes, bytes.count)
                precondition(count > 0)
                let request = String(decoding: bytes.prefix(count), as: UTF8.self)
                precondition(request.lowercased().contains("authorization: bearer synthetic-probe"))
                precondition(request.contains("/v1/runs/same-run/events"))
                if turn == 2 { precondition(request.lowercased().contains("last-event-id: 1")) }
                func send(_ s: String) {
                    let data = Data(s.utf8)
                    let sent = data.withUnsafeBytes { Darwin.write(conn, $0.baseAddress, $0.count) }
                    precondition(sent == data.count)
                }
                send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
                send("id: \(turn)\ndata: {\"run_id\":\"same-run\"}\n\n")
                try await Task.sleep(for: .milliseconds(1500))
                send("event: done\ndata: completed\n\n")
                Darwin.close(conn)
            }
            Darwin.close(listenFD)
        }
        for turn in 1...2 {
            let (config, _) = try await URLSessionConfiguration.tailscaleSession(phone)
            var proxies = config.proxyConfigurations
            proxies[0].allowFailover = false; config.proxyConfigurations = proxies
            let session = URLSession(configuration: config)
            var request = URLRequest(url: URL(string: "http://\(ip):8767/v1/runs/same-run/events")!); request.timeoutInterval = 15
            request.setValue("Bearer synthetic-probe", forHTTPHeaderField: "Authorization")
            if turn == 2 { request.setValue("1", forHTTPHeaderField: "Last-Event-ID") }
            let start = Date(); var first: Double?; var lines = [String]()
            let (bytes, response) = try await session.bytes(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            for try await line in bytes.lines { if first == nil { first = Date().timeIntervalSince(start) }; lines.append(line) }
            precondition(first! < Date().timeIntervalSince(start) - 1)
            precondition(lines.contains("id: \(turn)"))
            precondition(lines.contains("data: completed"))
            session.invalidateAndCancel()
            if turn == 1 {
                // The same private destination must fail after its embedded proxy closes.
                let blockedSession = URLSession(configuration: config)
                try await phone.close()
                var blocked = URLRequest(url: URL(string: "http://\(ip):8767/v1/runs/same-run/events")!)
                blocked.timeoutInterval = 3
                do { _ = try await blockedSession.data(for: blocked); preconditionFailure("Proxy silently fell back") }
                catch { }
                blockedSession.invalidateAndCancel()
                phone = try node("momo-poc-phone"); try await phone.up()
                let restoredIP = try await phone.addrs().ip4
                precondition(restoredIP == firstPhoneIP)
            }
        }
        try await service.value
        try await phone.close(); try await server.close()
        print("{\"passed\":true,\"two_swift_nodes\":true,\"sse_streamed_before_completion\":true,\"persistent_identity\":true,\"cursor_resumed\":true,\"public_account_used\":false,\"http_over_encrypted_tailnet\":true,\"production_forwarder\":true,\"https_certificates_disabled\":true,\"dead_proxy_no_fallback\":true}")
    }
}

#if os(macOS)
@main struct ProbeCLI {
    static func main() async throws {
        try await Probe.run(controlURL: CommandLine.arguments[1], root: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
#endif
