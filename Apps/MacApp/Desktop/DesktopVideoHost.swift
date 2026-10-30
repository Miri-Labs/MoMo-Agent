import AppKit
import MoMoAgentRTC

@MainActor final class DesktopVideoHost {
    private let tailnet: EmbeddedTailnet
    private let key: String
    private let endpoint: URL
    private let session: URLSession
    private var peers: [String: DesktopVideoPeer] = [:]
    private var attempts: [String: UUID] = [:]
    init(tailnet: EmbeddedTailnet, key: String, port: Int) {
        self.tailnet = tailnet; self.key = key
        endpoint = URL(string: "http://127.0.0.1:\(port)/desktop/rtc")!
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 3
        session = URLSession(configuration: config)
    }
    func offer(_ request: [String: Any]) async throws -> [String: Any] {
        guard let viewer = request["viewer"] as? String, let sdp = request["sdp"] as? String,
              let nonce = request["nonce"] as? String, UUID(uuidString: nonce) != nil,
              sdp.utf8.count <= 131072, peers.count + attempts.count < 4 else { throw DesktopRTCError.invalidSignal }
        let attempt = UUID(); attempts[viewer] = attempt
        peers.removeValue(forKey: viewer)?.close()
        let peer = try DesktopRTC(sending: true)
        var media: DesktopMediaRoute?
        let capture = DesktopVideoCapture()
        do {
            let route = try await DesktopMediaRoute.open(tailnet); media = route
            try await peer.remoteDescription(route.received(sdp), answer: false)
            let answer = try await peer.localDescription(answer: true)
            try await route.bind(local: answer, remote: sdp)
            guard attempts[viewer] == attempt, !Task.isCancelled else { throw CancellationError() }
            let entry = DesktopVideoPeer(rtc: peer, route: route, capture: capture)
            peers[viewer] = entry
            peer.handleControl = { [weak self] packet in
                guard let self, self.peers[viewer] === entry else { return (403, Data()) }
                entry.lastActivity = .now
                let response = await self.control(viewer: viewer, operation: packet.operation, body: packet.body)
                if ["claim", "release", "input"].contains(packet.operation) { self.tailnet.diagnostics.recordVideo(packet.operation, statistics: ["status": String(response.0)]) }
                return response
            }
            peer.onClose = { [weak self, weak entry] in
                guard let self, let entry, self.peers[viewer] === entry else { return }
                self.peers.removeValue(forKey: viewer); entry.close()
                self.tailnet.diagnostics.recordVideo("closed")
            }
            guard let source = peer.source, let capturer = peer.capturer else { throw DesktopRTCError.unavailable }
            try await capture.start(source: source, capturer: capturer, failed: { [weak peer] in peer?.close() })
            guard attempts[viewer] == attempt else { throw CancellationError() }
            attempts.removeValue(forKey: viewer)
            entry.watch = Task { [weak self, weak entry] in
                // Unclaimed offers and abandoned pages cannot keep capturing indefinitely.
                let deadline = ContinuousClock.now.advanced(by: .seconds(12))
                var counter = 0
                while let self, let entry, !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    if (!entry.rtc.controlReady && ContinuousClock.now > deadline) || entry.lastActivity.duration(to: .now) > .seconds(12) { entry.close(); return }
                    counter += 1
                    if counter % 5 == 0 { self.tailnet.diagnostics.recordVideo("sending", statistics: await entry.rtc.statistics()) }
                    let (code, data) = await self.control(viewer: viewer, operation: "status", body: Data("{}".utf8))
                    let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    if code != 200 || status?["screen"] as? Bool != true || status?["owner"] as? String == "other" { entry.close(); return }
                }
            }
            tailnet.diagnostics.recordVideo("answer")
            return ["version": 1, "nonce": nonce, "sdp": try route.advertised(answer)]
        } catch {
            if attempts[viewer] == attempt { attempts.removeValue(forKey: viewer) }
            peer.close(); await capture.stop(); await media?.close()
            throw error
        }
    }
    private func control(viewer: String, operation: String, body: Data) async -> (Int, Data) {
        guard ["status", "request", "claim", "release", "heartbeat", "input"].contains(operation), body.count <= 16384 else { return (400, Data()) }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["viewer":viewer, "operation":operation, "body":body.base64EncodedString()])
            let (data, response) = try await session.data(for: request)
            guard data.count <= 20000 else { return (502, Data()) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 503, data)
        } catch { return (503, Data("{\"error\":{\"message\":\"电脑操作暂时不可用。\"}}".utf8)) }
    }
    func stop() {
        attempts.removeAll()
        let previous = peers; peers.removeAll()
        for peer in previous.values { peer.close() }
        session.invalidateAndCancel()
    }
}

@MainActor private final class DesktopVideoPeer {
    let rtc: DesktopRTC
    let route: DesktopMediaRoute
    let capture: DesktopVideoCapture
    var watch: Task<Void, Never>?
    var lastActivity = ContinuousClock.now
    private var closed = false
    init(rtc: DesktopRTC, route: DesktopMediaRoute, capture: DesktopVideoCapture) { self.rtc = rtc; self.route = route; self.capture = capture }
    func close() {
        guard !closed else { return }; closed = true
        watch?.cancel(); watch = nil; rtc.handleControl = nil; rtc.close()
        Task { await capture.stop(); await route.close() }
    }
}
