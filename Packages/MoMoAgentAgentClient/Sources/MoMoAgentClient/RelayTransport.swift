import Foundation

/// Exclusive encrypted transport; a relay failure must never send credentials via plain HTTPS.
public struct RelayTransport: AgentTransport {
    public var requiresExclusiveRouting: Bool { true }
    private let endpoint: URL
    private let code: String

    public init(endpoint: URL, code: String) throws {
        try self.init(endpoint: endpoint, code: code, allowInsecureLoopback: false)
    }

    init(endpoint: URL, code: String, allowInsecureLoopback: Bool) throws {
        let loopback = allowInsecureLoopback && endpoint.scheme == "http" && endpoint.host == "127.0.0.1"
        guard endpoint.scheme == "https" || loopback, endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/",
              code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              Data(relayBase64URL: code)?.count == 32 else { throw RelayError.invalidConfiguration }
        self.endpoint = endpoint; self.code = code
    }

    public func open(_ request: URLRequest) async throws -> AgentByteStream? {
        guard let url = request.url, url.scheme == endpoint.scheme, url.host == endpoint.host,
              url.port == endpoint.port, url.user == nil, url.password == nil, url.fragment == nil,
              request.httpBodyStream == nil else { throw RelayError.invalidConfiguration }
        guard (request.httpBody?.count ?? 0) <= 512 * 1024 else { throw RelayError.requestTooLarge }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        components.path = "/c/\(RelayCipher.routingToken(code: code))/__alma_e2e__"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects.shared, delegateQueue: nil)
        let socket = session.webSocketTask(with: components.url!)
        socket.maximumMessageSize = 1024 * 1024
        let exchange = RelayExchange(session: session, socket: socket, code: code)
        return try await withTaskCancellationHandler {
            try await exchange.open(request)
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }
}

/// One socket per HTTP exchange isolates cancellation and bounded body buffering.
private actor RelayExchange {
    let session: URLSession
    let socket: URLSessionWebSocketTask
    var cipher: RelayCipher
    let id = UUID().uuidString

    init(session: URLSession, socket: URLSessionWebSocketTask, code: String) {
        self.session = session; self.socket = socket; self.cipher = RelayCipher(code: code)
    }

    func receive(timeout: Double) async throws -> URLSessionWebSocketTask.Message {
        let socket = socket
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        return try await socket.receive()
    }

    func open(_ request: URLRequest) async throws -> AgentByteStream {
        do {
            try Task.checkCancellation()
            socket.resume()
            try await socket.send(.string(String(decoding: JSONEncoder().encode(cipher.hello()), as: UTF8.self)))
            guard case .string(let hello) = try await receive(timeout: 15), hello.utf8.count <= 2048 else { throw RelayError.authentication }
            let confirmation = try cipher.accept(JSONDecoder().decode(RelayFrame.self, from: Data(hello.utf8)))
            try await socket.send(.string(String(decoding: JSONEncoder().encode(confirmation), as: UTF8.self)))
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let path = url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
            let frame = RelayFrame(t: "hreq", id: id, method: request.httpMethod ?? "GET", path: path,
                                   headers: request.allHTTPHeaderFields ?? [:], b: request.httpBody?.base64EncodedString())
            try await socket.send(.data(cipher.seal(frame)))
            guard case .data(let data) = try await receive(timeout: min(max(request.timeoutInterval, 15), 120)) else { throw RelayError.protocolFailure }
            let head = try cipher.open(data)
            if head.t == "herr" { throw RelayError.unavailable }
            guard head.t == "hres", head.id == id, let status = head.status, (100...599).contains(status) else { throw RelayError.protocolFailure }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
            let worker = Task { await self.readBody(continuation) }
            let session = session, socket = socket
            let cancel: @Sendable () -> Void = {
                worker.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            continuation.onTermination = { _ in cancel() }
            let headers = (head.headers ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            return AgentByteStream(status: status, contentType: headers["content-type"]?.components(separatedBy: ";").first,
                                   retryAfter: headers["retry-after"], chunks: stream, cancel: cancel)
        } catch {
            close()
            throw error
        }
    }

    func readBody(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) async {
        defer { close() }
        do {
            while true {
                try Task.checkCancellation()
                guard case .data(let data) = try await receive(timeout: 75) else { throw RelayError.protocolFailure }
                let frame = try cipher.open(data)
                guard frame.id == id else { throw RelayError.protocolFailure }
                switch frame.t {
                case "hchunk":
                    guard let encoded = frame.b, let chunk = Data(base64Encoded: encoded), chunk.count <= 32768 else { throw RelayError.protocolFailure }
                    if case .dropped = continuation.yield(chunk) { throw AgentClientError.responseTooLarge }
                case "hend": continuation.finish(); return
                case "herr": throw RelayError.unavailable
                default: throw RelayError.protocolFailure
                }
            }
        } catch { continuation.finish(throwing: error) }
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
