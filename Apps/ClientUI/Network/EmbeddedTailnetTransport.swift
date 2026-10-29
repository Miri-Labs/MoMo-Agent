import Foundation
import MoMoAgentClient

struct EmbeddedTailnetTransport: AgentTransport {
    let network: EmbeddedTailnet
    let endpoint: URL
    let requiresExclusiveRouting = true

    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        guard TailnetEndpoint.isOrigin(endpoint), let url = request.url, TailnetEndpoint.accepts(url),
              url.host == endpoint.host, url.port == endpoint.port else { throw TailnetError.invalidEndpoint }
        await network.diagnostics.observePeer(endpoint.host)
        let desktop = url.path.hasPrefix("/desktop/")
        let media = desktop && ["frame", "frames"].contains(url.lastPathComponent)
        let session = try await network.connectedSession(interactive: request.networkServiceType == .responsiveData,
                                                          desktopControl: desktop && !media, media: media)
        do {
            if url.path == "/desktop/v1/frames" {
                let diagnostics = await network.diagnostics
                return try await AgentHTTPStream.open(request, configuration: session.configuration) { metrics in
                    diagnostics.record(metrics, request: request)
                }
            }
            if desktop {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, data.count <= 3 * 1024 * 1024 else { throw URLError(.networkConnectionLost) }
                return AgentByteStream(status: response.statusCode, contentType: response.mimeType, chunks: AsyncThrowingStream { continuation in
                    continuation.yield(data); continuation.finish()
                })
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.networkConnectionLost) }
            let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
                let task = Task {
                    do {
                        var buffer = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation(); buffer.append(byte)
                            if byte == 10 || buffer.count >= 8192 {
                                if case .dropped = continuation.yield(buffer) { throw URLError(.networkConnectionLost) }
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty, case .dropped = continuation.yield(buffer) { throw URLError(.networkConnectionLost) }
                        continuation.finish()
                    } catch { await network.failedRequest(error, session: session); continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return AgentByteStream(status: response.statusCode, contentType: response.mimeType, retryAfter: response.value(forHTTPHeaderField: "Retry-After"), chunks: stream)
        } catch { await network.failedRequest(error, session: session); throw error }
    }
}
