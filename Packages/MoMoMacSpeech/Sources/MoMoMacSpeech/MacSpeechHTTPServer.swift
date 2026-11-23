import Foundation
import Network

/// Loopback-only HTTP/1.1 service exposing native CoreML speech capabilities to `context_server.py`:
///   - `GET  /internal/v1/health`
///   - `POST /internal/v1/vad`
///   - `POST /internal/v1/transcribe-window`
///   - `POST /internal/v1/embed`
///   - `POST /internal/v1/dictate`
///   - `POST /internal/v1/unload`
public final class MacSpeechHTTPServer: @unchecked Sendable {
    public let port: UInt16
    public let authToken: String
    public let bundleManager: CoreMLBundleManager

    private let listenerQueue = DispatchQueue(label: "com.momoagent.macspeech.http", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "com.momoagent.macspeech.inference", qos: .userInitiated)
    private var listener: NWListener?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(port: UInt16, authToken: String, bundleManager: CoreMLBundleManager) {
        self.port = port
        self.authToken = authToken
        self.bundleManager = bundleManager
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SpeechEngineError.invalidRequest("Invalid port: \(port)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let l = try NWListener(using: params)
        let readySem = DispatchSemaphore(value: 0)
        final class StartState: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var error: Error?
            func finish(error: Error? = nil) -> Bool {
                lock.lock(); defer { lock.unlock() }
                if finished { return false }
                finished = true
                self.error = error
                return true
            }
            func currentError() -> Error? {
                lock.lock(); defer { lock.unlock() }
                return error
            }
        }
        let stateBox = StartState()

        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if stateBox.finish(error: nil) { readySem.signal() }
            case .waiting(let err):
                if stateBox.finish(error: err) { readySem.signal() }
            case .failed(let err):
                if stateBox.finish(error: err) { readySem.signal() }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.start(queue: listenerQueue)
        self.listener = l

        let waitResult = readySem.wait(timeout: .now() + 3)
        if waitResult == .timedOut {
            _ = stateBox.finish(error: SpeechEngineError.invalidRequest("Timed out binding MacSpeechHTTPServer on port \(port)"))
            l.cancel()
            self.listener = nil
            throw stateBox.currentError() ?? SpeechEngineError.invalidRequest("Timed out starting speech server")
        }
        if let startError = stateBox.currentError() {
            l.cancel()
            self.listener = nil
            throw startError
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP/1.1 connection framing

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: listenerQueue)
        receiveRequest(conn: conn, buffer: Data())
    }

    private func receiveRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }
            if error != nil {
                conn.cancel()
                return
            }
            var acc = buffer
            if let data { acc.append(data) }

            let headerSep = Data("\r\n\r\n".utf8)
            if let sepRange = acc.range(of: headerSep) {
                let headerData = acc[..<sepRange.lowerBound]
                let bodyStart = sepRange.upperBound
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    self.sendResponse(conn: conn, status: 400, json: ["error": "Invalid HTTP headers"])
                    return
                }
                let lines = headerText.components(separatedBy: "\r\n")
                guard let reqLine = lines.first else {
                    self.sendResponse(conn: conn, status: 400, json: ["error": "Empty request"])
                    return
                }
                let parts = reqLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else {
                    self.sendResponse(conn: conn, status: 400, json: ["error": "Malformed request line"])
                    return
                }
                let method = String(parts[0])
                let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let maxBodyBytes = 16 * 1024 * 1024
                let rawLength = headers["content-length"] ?? "0"
                guard let contentLength = Int(rawLength), contentLength >= 0, contentLength <= maxBodyBytes else {
                    self.sendResponse(conn: conn, status: 400, json: ["error": "Invalid or oversized Content-Length"])
                    return
                }
                let receivedBodyBytes = acc.count - bodyStart
                if receivedBodyBytes < contentLength {
                    if isComplete {
                        self.sendResponse(conn: conn, status: 400, json: ["error": "Truncated HTTP request body"])
                        return
                    }
                    self.receiveRequest(conn: conn, buffer: acc)
                    return
                }
                let body = Data(acc[bodyStart..<(bodyStart + contentLength)])
                self.dispatchRequest(conn: conn, method: method, path: rawPath, headers: headers, body: body)
                return
            }

            if isComplete || acc.count > 16 * 1024 * 1024 {
                self.sendResponse(conn: conn, status: 400, json: ["error": "Incomplete or oversized request"])
                return
            }
            self.receiveRequest(conn: conn, buffer: acc)
        }
    }

    private func dispatchRequest(
        conn: NWConnection,
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) {
        if method == "GET" && path == "/internal/v1/health" {
            let st = bundleManager.status()
            sendEncodable(conn: conn, status: 200, value: st)
            return
        }

        // Authenticate all mutating/inference endpoints if token configured
        if !authToken.isEmpty {
            let expected = "Bearer \(authToken)"
            if headers["authorization"] != expected {
                sendResponse(conn: conn, status: 401, json: ["error": "Unauthorized"])
                return
            }
        }

        workerQueue.async { [weak self] in
            guard let self else { return }
            do {
                switch (method, path) {
                case ("POST", "/internal/v1/vad"):
                    let req = try self.decoder.decode(VADRequest.self, from: body)
                    let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: req.audioPath))
                    let res = self.bundleManager.getVAD().detectSpeech(
                        samples: decoded.samples,
                        threshold: req.threshold ?? 0.45,
                        minSpeechSec: req.minSpeechSec ?? 0.25,
                        minSilenceSec: req.minSilenceSec ?? 0.50
                    )
                    self.sendEncodable(conn: conn, status: 200, value: res)

                case ("POST", "/internal/v1/transcribe-window"):
                    let req = try self.decoder.decode(TranscribeWindowRequest.self, from: body)
                    guard !req.audioPaths.isEmpty else {
                        throw SpeechEngineError.invalidRequest("audio_paths must not be empty")
                    }
                    let urls = req.audioPaths.map { URL(fileURLWithPath: $0) }
                    let (decoded, _) = try AudioDecoder.decodeConcatenated(urls: urls)
                    let normalized = AudioDecoder.applyGentleGainNormalization(decoded.samples)
                    let moss = try self.bundleManager.getMOSS()
                    let tx = try moss.transcribe(
                        samples: normalized,
                        hotwords: req.hotwords ?? [],
                        languageHint: req.languageHint,
                        allowBisectRetry: req.allowBisectRetry ?? true
                    )

                    var speakerEmbeddings: [SpeakerClusterEmbedding] = []
                    if (req.extractSpeakerEmbeddings ?? true) && self.bundleManager.redimnetAvailable && !tx.segments.isEmpty {
                        if let encoder = try? self.bundleManager.getReDimNet() {
                            let segInputs = tx.segments.map {
                                SpeakerSegmentInput(speakerTag: $0.speakerTag, startSec: $0.startSec, endSec: $0.endSec)
                            }
                            speakerEmbeddings = encoder.extractPerSpeakerEmbeddings(
                                windowSamples: decoded.samples,
                                segments: segInputs,
                                vad: self.bundleManager.getVAD()
                            )
                        }
                    }

                    let resp = TranscribeWindowResponse(
                        segments: tx.segments,
                        speakerEmbeddings: speakerEmbeddings,
                        rawText: tx.rawText,
                        durationSec: tx.durationSec,
                        encodeSec: tx.encodeSec,
                        decodeSec: tx.decodeSec,
                        totalSec: tx.totalSec,
                        generatedTokens: tx.generatedTokens,
                        possiblyTruncated: tx.possiblyTruncated,
                        retriedWithBisection: tx.retriedWithBisection,
                        acceleratorMask: tx.acceleratorMask
                    )
                    self.sendEncodable(conn: conn, status: 200, value: resp)

                case ("POST", "/internal/v1/embed"):
                    let req = try self.decoder.decode(EmbedRequest.self, from: body)
                    let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: req.audioPath))
                    let slice: [Float]
                    if let s = req.startSec, let e = req.endSec, e > s {
                        slice = AudioDecoder.slice(decoded.samples, startSec: s, endSec: e)
                    } else {
                        slice = decoded.samples
                    }
                    let encoder = try self.bundleManager.getReDimNet()
                    let vad = (req.applyVad ?? true) ? self.bundleManager.getVAD() : nil
                    let res = try encoder.extractEmbedding(
                        samples: slice,
                        vad: vad,
                        requireMinSeconds: req.minSeconds ?? ReDimNetVoiceEncoder.minCleanSeconds
                    )
                    self.sendEncodable(conn: conn, status: 200, value: res)

                case ("POST", "/internal/v1/dictate"):
                    let req = try self.decoder.decode(DictateRequest.self, from: body)
                    let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: req.audioPath))
                    let normalized = AudioDecoder.applyGentleGainNormalization(decoded.samples)
                    let moss = try self.bundleManager.getMOSS()
                    let res = try moss.dictate(samples: normalized, hotwords: req.hotwords ?? [])
                    self.sendEncodable(
                        conn: conn,
                        status: 200,
                        value: DictateResponse(text: res.text, durationSec: res.durationSec, elapsedSec: res.elapsedSec)
                    )

                case ("POST", "/internal/v1/unload"):
                    self.bundleManager.unloadHeavyModels()
                    self.sendResponse(conn: conn, status: 200, json: ["ok": true])

                default:
                    self.sendResponse(conn: conn, status: 404, json: ["error": "Not found: \(method) \(path)"])
                }
            } catch {
                self.sendResponse(conn: conn, status: 422, json: ["error": error.localizedDescription])
            }
        }
    }

    private func sendEncodable<T: Encodable>(conn: NWConnection, status: Int, value: T) {
        do {
            let payload = try encoder.encode(value)
            sendRaw(conn: conn, status: status, body: payload)
        } catch {
            sendResponse(conn: conn, status: 500, json: ["error": error.localizedDescription])
        }
    }

    private func sendResponse(conn: NWConnection, status: Int, json: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        sendRaw(conn: conn, status: status, body: payload)
    }

    private func sendRaw(conn: NWConnection, status: Int, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 422: reason = "Unprocessable Entity"
        default: reason = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Wire DTOs

private struct VADRequest: Decodable {
    let audioPath: String
    let threshold: Double?
    let minSpeechSec: Double?
    let minSilenceSec: Double?
}

private struct TranscribeWindowRequest: Decodable {
    let audioPaths: [String]
    let hotwords: [String]?
    let languageHint: String?
    let extractSpeakerEmbeddings: Bool?
    let allowBisectRetry: Bool?
}

private struct TranscribeWindowResponse: Encodable {
    let segments: [MOSSSegment]
    let speakerEmbeddings: [SpeakerClusterEmbedding]
    let rawText: String
    let durationSec: Double
    let encodeSec: Double
    let decodeSec: Double
    let totalSec: Double
    let generatedTokens: Int
    let possiblyTruncated: Bool
    let retriedWithBisection: Bool
    let acceleratorMask: Int32
}

private struct EmbedRequest: Decodable {
    let audioPath: String
    let startSec: Double?
    let endSec: Double?
    let applyVad: Bool?
    let minSeconds: Double?
}

private struct DictateRequest: Decodable {
    let audioPath: String
    let hotwords: [String]?
}

private struct DictateResponse: Encodable {
    let text: String
    let durationSec: Double
    let elapsedSec: Double
}
