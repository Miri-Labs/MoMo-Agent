import Foundation

/// Multipart framing is parsed before dropping obsolete *complete* pictures.
/// Dropping arbitrary byte chunks would corrupt JPEGs and freeze presentation.
public struct DesktopPicture: Sendable, Equatable {
    public let jpeg: Data
    public let streamID: String
    public let sequence: Int
}

struct DesktopJPEGParser {
    private var buffer = Data()
    private var length: Int?
    private var streamID = ""
    private var sequence = 0
    private let delimiter = Data("\r\n\r\n".utf8)
    mutating func append(_ data: Data) throws -> [DesktopPicture] {
        buffer.append(data)
        var frames: [DesktopPicture] = []
        while true {
            if length == nil {
                guard let end = buffer.range(of: delimiter) else {
                    guard buffer.count <= 512 else { throw AgentClientError.invalidResponse }; break
                }
                guard end.upperBound - buffer.startIndex <= 512,
                      let header = String(data: buffer[..<end.lowerBound], encoding: .ascii),
                      header.hasPrefix("--momo-frame\r\n"),
                      header.lowercased().contains("content-type: image/jpeg"),
                      let field = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let size = Int(field.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                      size > 4, size <= 512 * 1024 else { throw AgentClientError.invalidResponse }
                let fields = header.components(separatedBy: "\r\n")
                guard let identifier = fields.first(where: { $0.hasPrefix("X-Stream-ID: ") }).map({ String($0.dropFirst(13)) }),
                      UUID(uuidString: identifier) != nil,
                      let number = fields.first(where: { $0.hasPrefix("X-Frame-Sequence: ") }).flatMap({ Int($0.dropFirst(18)) }), number > 0
                else { throw AgentClientError.invalidResponse }
                streamID = identifier; sequence = number
                length = size; buffer.removeSubrange(..<end.upperBound)
            }
            guard let size = length, buffer.count >= size + 2 else { break }
            let picture = Data(buffer.prefix(size))
            guard picture.starts(with: [0xff, 0xd8]), picture.suffix(2).elementsEqual([0xff, 0xd9]),
                  buffer.dropFirst(size).prefix(2).elementsEqual([13, 10]) else { throw AgentClientError.invalidResponse }
            frames.append(DesktopPicture(jpeg: picture, streamID: streamID, sequence: sequence))
            buffer.removeFirst(size + 2); length = nil
        }
        guard buffer.count <= 512 * 1024 + 514 else { throw AgentClientError.responseTooLarge }
        return frames
    }
}

/// Chunk delivery avoids an async suspension for every byte of a screen image.
/// Configuration is supplied by the route owner, including the private SOCKS proxy.
public final class AgentHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var head: CheckedContinuation<AgentByteStream, Error>?
    private var session: URLSession?
    private var cancelled = false
    private let output = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    private let metrics: @Sendable (URLSessionTaskMetrics) -> Void

    private init(metrics: @escaping @Sendable (URLSessionTaskMetrics) -> Void) { self.metrics = metrics }

    public static func open(_ request: URLRequest, configuration: URLSessionConfiguration,
                            metrics: @escaping @Sendable (URLSessionTaskMetrics) -> Void = { _ in }) async throws -> AgentByteStream {
        let owner = AgentHTTPStream(metrics: metrics)
        owner.output.continuation.onTermination = { _ in owner.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.lock.withLock {
                    if owner.cancelled { continuation.resume(throwing: CancellationError()); return }
                    owner.head = continuation
                    let session = URLSession(configuration: configuration, delegate: owner, delegateQueue: nil)
                    owner.session = session
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: { owner.cancel() }
    }

    private func cancel() {
        let (head, session) = lock.withLock {
            cancelled = true
            let value = (self.head, self.session); self.head = nil; self.session = nil; return value
        }
        head?.resume(throwing: CancellationError()); session?.invalidateAndCancel()
        output.continuation.finish(throwing: CancellationError())
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let head = lock.withLock { let value = self.head; self.head = nil; return value }
        guard let response = response as? HTTPURLResponse else {
            head?.resume(throwing: AgentClientError.invalidResponse); completionHandler(.cancel); return
        }
        head?.resume(returning: AgentByteStream(status: response.statusCode, contentType: response.mimeType,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"), chunks: output.stream, cancel: { self.cancel() }))
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if case .dropped = output.continuation.yield(data) {
            output.continuation.finish(throwing: AgentClientError.responseTooLarge); cancel()
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let head = lock.withLock { let value = self.head; self.head = nil; self.session = nil; return value }
        head?.resume(throwing: error ?? AgentClientError.invalidResponse)
        if let error { output.continuation.finish(throwing: error) } else { output.continuation.finish() }
        session.finishTasksAndInvalidate()
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) { self.metrics(metrics) }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
