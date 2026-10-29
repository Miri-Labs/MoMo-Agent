import Foundation
import Observation
import MoMoAgentClient
@preconcurrency import WebRTC

/// One paired network connection, independent of the Agent and its durable operation journal.
@MainActor @Observable
public final class AgentRTCTransport: NSObject, AgentTransport {
    public enum Route: String, Sendable { case https, negotiating, webrtc, direct, relay }
    public private(set) var route = Route.https
    public private(set) var lastFailure: String?
    public var routeLabel: String {
        switch route {
        case .https, .negotiating: "HTTPS"
        case .webrtc: "WebRTC"
        case .direct: "WebRTC 直连"
        case .relay: "WebRTC 中继"
        }
    }
    @ObservationIgnored private let connection: AgentConnection
    @ObservationIgnored private let identity: RTCIdentity
    @ObservationIgnored private let credential: String
    @ObservationIgnored private let signaling: URLSession
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var channel: RTCDataChannel?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var negotiation: Task<Void, Error>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var nonce = ""
    @ObservationIgnored private var sessionID = ""
    @ObservationIgnored private var maxRequestBytes = 32768
    @ObservationIgnored private var phase: Phase?
    @ObservationIgnored private var pending: [String: Pending] = [:]

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    @MainActor private final class Phase {
        let id = UUID()
        let kind: String
        let continuation: CheckedContinuation<String, Error>
        init(_ kind: String, _ continuation: CheckedContinuation<String, Error>) {
            self.kind = kind; self.continuation = continuation
        }
    }

    @MainActor private final class Pending {
        var header: CheckedContinuation<AgentByteStream?, Error>?
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var timer: Task<Void, Never>?
        var receivedHead = false
        init() {
            (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        }
    }

    public init(connection: AgentConnection, credential: String) throws {
        let url = connection.baseURL, host = connection.baseURL.host?.lowercased() ?? ""
        guard url.scheme == "https" || url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AgentClientError.invalidEndpoint
        }
        guard !credential.isEmpty, !credential.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentClientError.invalidCredential
        }
        self.connection = connection; self.credential = credential; identity = RTCIdentity(connection)
        signaling = URLSession(configuration: .ephemeral, delegate: SignalNoRedirects(), delegateQueue: nil)
        super.init()
    }

    public func resume() { suspended = false; nextAttempt = .distantPast }

    public func suspend() {
        suspended = true
        disconnect(CancellationError(), retryAfter: 0)
    }

    public func connect() async throws {
        if authenticated { return }
        beginNegotiation()
        guard let negotiation else { throw AgentRTCError.unavailable }
        try await negotiation.value
    }

    public func open(_ request: URLRequest) async throws -> AgentByteStream? {
        try Task.checkCancellation()
        // Video must not queue ahead of input/heartbeats on the ordered control channel.
        if request.url?.path == "/desktop/v1/frames" { return nil }
        guard !suspended else { return nil }
        guard authenticated, let channel, channel.readyState == .open else {
            beginNegotiation()
            return nil
        }
        guard let url = request.url, url.scheme == connection.baseURL.scheme,
              url.host == connection.baseURL.host, url.port == connection.baseURL.port,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + credential else { return nil }
        let id = UUID().uuidString.lowercased()
        var headers: [String: String] = [:]
        for key in ["Idempotency-Key", "Last-Event-ID", "Accept"] {
            if let value = request.value(forHTTPHeaderField: key) { headers[key] = value }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        let path = url.path + (query.map { "?" + $0 } ?? "")
        let body = try JSONEncoder().encode(RTCRequest(id: id, method: request.httpMethod ?? "GET", path: path,
            headers: headers, body: (request.httpBody ?? Data()).base64EncodedString()))
        // A large request stays on HTTP before dispatch; buffered writes are never replayed here.
        guard body.count <= maxRequestBytes, channel.bufferedAmount < 262144, pending.count < 16 else { return nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let item = Pending(); item.header = continuation
                item.continuation.onTermination = { @Sendable [weak self] _ in
                    Task { @MainActor in self?.cancel(id) }
                }
                pending[id] = item
                armTimeout(id)
                guard channel.sendData(RTCDataBuffer(data: body, isBinary: false)) else {
                    disconnect(AgentRTCError.disconnected); return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func beginNegotiation() {
        guard !suspended, !authenticated, negotiation == nil, nextAttempt <= Date() else { return }
        let token = UUID(); generation = token; route = .negotiating
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.generation == token else { return }
            self.disconnect(AgentRTCError.timeout)
        }
        negotiation = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await self.negotiate(token)
                guard self.generation == token else { throw CancellationError() }
                self.deadline?.cancel(); self.deadline = nil; self.negotiation = nil; self.lastFailure = nil
            } catch {
                if self.generation == token { self.disconnect(error) }
                throw error
            }
        }
    }

    private func signal(_ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("transport/v1/" + path))
        request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await signaling.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 262144 else { throw AgentRTCError.unavailable }
        return data
    }

    private func negotiate(_ token: UUID) async throws {
        let options = try JSONDecoder().decode(RTCOptions.self, from: await signal("config"))
        guard generation == token else { throw CancellationError() }
        guard options.available, options.protocolName == rtcProtocol else { throw AgentRTCError.unavailable }
        guard options.identity == identity else { throw AgentRTCError.identityChanged }
        guard ["all", "relay"].contains(options.iceTransportPolicy), options.iceServers.count <= 8 else { throw AgentRTCError.invalidFrame }
        maxRequestBytes = min(32768, max(1024, options.maxRequestBytes))
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceTransportPolicy = options.iceTransportPolicy == "relay" ? .relay : .all
        configuration.iceServers = options.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        guard let peer = Self.factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw AgentRTCError.unavailable
        }
        self.peer = peer
        let channelConfig = RTCDataChannelConfiguration(); channelConfig.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: rtcProtocol, configuration: channelConfig) else { throw AgentRTCError.unavailable }
        self.channel = channel; channel.delegate = self
        let sdp = try await sdkPhase { callback in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                callback(error.map { .failure($0) } ?? description.map { .success($0.sdp) } ?? .failure(AgentRTCError.invalidFrame))
            }
        }
        _ = try await sdkPhase { callback in
            peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                callback(error.map { .failure($0) } ?? .success(""))
            }
        }
        if peer.iceGatheringState != .complete {
            // An unreachable interface/ICE server must not hold back already gathered candidates.
            let token = generation
            let gatheringDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.generation == token, self.phase?.kind == "gather" else { return }
                let sdp = peer.localDescription?.sdp ?? ""
                let usable = options.iceTransportPolicy == "relay" ? sdp.contains(" typ relay") : sdp.contains("a=candidate:")
                let continuation = self.phase?.continuation; self.phase = nil
                if usable { continuation?.resume(returning: "") }
                else { continuation?.resume(throwing: AgentRTCError.timeout) }
            }
            defer { gatheringDeadline.cancel() }
            _ = try await waitingPhase("gather")
        }
        guard generation == token, let gathered = peer.localDescription?.sdp else { throw AgentRTCError.disconnected }
        nonce = UUID().uuidString.lowercased()
        let answer = try JSONDecoder().decode(RTCFrame.self,
            from: await signal("offer", body: JSONEncoder().encode(RTCOffer(identity: identity, nonce: nonce, sdp: gathered))))
        guard generation == token else { throw CancellationError() }
        guard answer.identity == identity, answer.nonce == nonce else { throw AgentRTCError.identityChanged }
        guard answer.type == "answer", answer.protocolName == rtcProtocol, let sdp = answer.sdp,
              let sessionID = answer.sessionID, UUID(uuidString: sessionID) != nil else { throw AgentRTCError.invalidFrame }
        self.sessionID = sessionID
        _ = try await sdkPhase { callback in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                callback(error.map { .failure($0) } ?? .success(""))
            }
        }
        if !authenticated { _ = try await waitingPhase("hello") }
    }

    private func sdkPhase(_ perform: (@escaping @Sendable (Result<String, Error>) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let value = Phase("sdk", continuation); phase = value; let token = generation; let id = value.id
            perform { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token, self.phase?.id == id else { return }
                    self.phase = nil; continuation.resume(with: result)
                }
            }
        }
    }

    private func waitingPhase(_ kind: String) async throws -> String {
        try await withCheckedThrowingContinuation { phase = Phase(kind, $0) }
    }

    private func receive(_ data: Data, channelID: ObjectIdentifier) {
        guard let channel, ObjectIdentifier(channel) == channelID else { return }
        do {
            guard data.count <= 32768 else { throw AgentRTCError.invalidFrame }
            let frame = try JSONDecoder().decode(RTCFrame.self, from: data)
            if frame.kind == "hello" {
                guard frame.identity == identity, frame.nonce == nonce, frame.sessionID == sessionID,
                      frame.protocolName == rtcProtocol, !authenticated else { throw AgentRTCError.identityChanged }
                authenticated = true; route = .webrtc; updateStatistics()
                if phase?.kind == "hello" { let continuation = phase?.continuation; phase = nil; continuation?.resume(returning: "") }
                return
            }
            guard authenticated, let id = frame.id else { throw AgentRTCError.invalidFrame }
            guard let item = pending[id] else { return } // A cancelled observer may still have in-flight chunks.
            armTimeout(id)
            switch frame.kind {
            case "head":
                guard !item.receivedHead, let status = frame.status, (100...599).contains(status) else { throw AgentRTCError.invalidFrame }
                item.receivedHead = true
                let continuation = item.header; item.header = nil
                continuation?.resume(returning: AgentByteStream(status: status, contentType: frame.contentType, retryAfter: frame.retryAfter, chunks: item.stream))
            case "chunk":
                guard item.receivedHead, let body = frame.body, let bytes = Data(base64Encoded: body), bytes.count <= 12000 else { throw AgentRTCError.invalidFrame }
                if case .dropped = item.continuation.yield(bytes) { throw AgentRTCError.bufferFull }
            case "end":
                guard item.receivedHead else { throw AgentRTCError.invalidFrame }
                pending.removeValue(forKey: id); item.timer?.cancel(); item.continuation.finish()
            case "error": disconnect(AgentRTCError.disconnected)
            default: throw AgentRTCError.invalidFrame
            }
        } catch { disconnect(error) }
    }

    private func armTimeout(_ id: String) {
        guard let item = pending[id] else { return }
        item.timer?.cancel()
        item.timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.pending[id] != nil else { return }
            self.disconnect(AgentRTCError.timeout)
        }
    }

    private func cancel(_ id: String) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timer?.cancel(); item.header?.resume(throwing: CancellationError()); item.header = nil
        item.continuation.finish(throwing: CancellationError())
        if let channel, channel.readyState == .open,
           let data = try? JSONSerialization.data(withJSONObject: ["kind": "cancel", "id": id]) {
            _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
    }

    private func disconnect(_ error: Error, retryAfter: TimeInterval = 30) {
        generation = UUID(); authenticated = false; route = .https
        if !(error is CancellationError) { lastFailure = error.localizedDescription }
        nextAttempt = Date().addingTimeInterval(retryAfter)
        negotiation?.cancel(); negotiation = nil; deadline?.cancel(); deadline = nil
        let previousPhase = phase; phase = nil; previousPhase?.continuation.resume(throwing: error)
        let previous = pending; pending.removeAll()
        for item in previous.values {
            item.timer?.cancel(); item.header?.resume(throwing: error); item.header = nil
            item.continuation.finish(throwing: error)
        }
        let oldChannel = channel, oldPeer = peer
        channel = nil; peer = nil
        oldChannel?.delegate = nil; oldChannel?.close(); oldPeer?.delegate = nil; oldPeer?.close()
    }

    private func updateStatistics() {
        guard let peer else { return }
        let token = generation
        peer.statistics { [weak self] report in
            let transport = report.statistics.values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }
            let pairID = transport?.values["selectedCandidatePairId"] as? String
            let pair = pairID.flatMap { report.statistics[$0] }
            let ids = [pair?.values["localCandidateId"] as? String, pair?.values["remoteCandidateId"] as? String].compactMap { $0 }
            let kinds = ids.compactMap { report.statistics[$0]?.values["candidateType"] as? String }
            let route: Route = kinds.contains("relay") ? .relay : kinds.count == 2 ? .direct : .webrtc
            Task { @MainActor in
                guard let self, self.generation == token, self.authenticated else { return }
                self.route = route
            }
        }
    }
}

extension AgentRTCTransport: RTCDataChannelDelegate {
    nonisolated public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let id = ObjectIdentifier(dataChannel), closed = dataChannel.readyState == .closed || dataChannel.readyState == .closing
        Task { @MainActor [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == id else { return }
            if closed { self.disconnect(AgentRTCError.disconnected) }
        }
    }
    nonisolated public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let id = ObjectIdentifier(dataChannel), data = buffer.data
        Task { @MainActor [weak self] in self?.receive(data, channelID: id) }
    }
}

extension AgentRTCTransport: RTCPeerConnectionDelegate {
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let id = ObjectIdentifier(peerConnection), failed = [.failed, .closed, .disconnected].contains(newState)
        Task { @MainActor [weak self] in
            guard let self, let peer = self.peer, ObjectIdentifier(peer) == id else { return }
            if failed { self.disconnect(AgentRTCError.disconnected) }
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let id = ObjectIdentifier(peerConnection), complete = newState == .complete
        Task { @MainActor [weak self] in
            guard let self, let peer = self.peer, ObjectIdentifier(peer) == id, complete, self.phase?.kind == "gather" else { return }
            let continuation = self.phase?.continuation; self.phase = nil; continuation?.resume(returning: "")
        }
    }
}

private final class SignalNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
