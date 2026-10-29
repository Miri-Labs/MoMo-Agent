import Foundation
import os
import Testing
import MoMoContracts
@testable import MoMoSpeech

@Suite(.serialized)
struct SpeechModelInstallerTests {
    @Test func interruptedDownloadResumesAndCorruptInstallIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<100).map(UInt8.init))
        let catalog = DownloadableSpeechModel(identifier: "test", baseURL: URL(string: "https://speech-model.test/")!,
            files: [.init(path: "nested/model.onnx", asset: "model.onnx", byteCount: 100, sha256: ContentHash.sha256(payload))])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ModelFixtureProtocol.state.withLock { $0 = .init(payload: payload, failAt: 32) }
        let installer = try SpeechModelInstaller(catalog: catalog, directory: root, session: session, rangeBytes: 32)
        await #expect(throws: URLError.self) { try await installer.install { _ in } }
        #expect(try await installer.installedDirectory() == nil)
        let revision = try catalog.revision
        let partial = root.appendingPathComponent(revision + ".partial/nested/model.onnx.download")
        #expect(try Data(contentsOf: partial) == payload.prefix(32))
        ModelFixtureProtocol.state.withLock { $0.failAt = nil; $0.offsets = [] }
        let installed = try await installer.install { _ in }
        #expect(ModelFixtureProtocol.state.withLock { $0.offsets } == [32, 64, 96])
        #expect(try Data(contentsOf: installed.appendingPathComponent("nested/model.onnx")) == payload)
        #expect(try await installer.installedDirectory() == installed)
        try Data(repeating: 0, count: 100).write(to: installed.appendingPathComponent("nested/model.onnx"))
        #expect(try await installer.installedDirectory() == nil)
        try await installer.remove()
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    @Test func wrongRangeResponseNeverPublishesTheModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 7, count: 50)
        let catalog = DownloadableSpeechModel(identifier: "test", baseURL: URL(string: "https://speech-model.test/")!,
            files: [.init(path: "model.onnx", asset: "model.onnx", byteCount: 50, sha256: ContentHash.sha256(payload))])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ModelFixtureProtocol.state.withLock { $0 = .init(payload: payload, wrongRange: true) }
        let installer = try SpeechModelInstaller(catalog: catalog, directory: root, session: session, rangeBytes: 32)
        await #expect(throws: SpeechModelInstallationError.invalidResponse) {
            try await installer.install { _ in }
        }
        #expect(try await installer.installedDirectory() == nil)
    }
}

private final class ModelFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var payload = Data()
        var failAt: Int?
        var wrongRange = false
        var offsets: [Int] = []
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "speech-model.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
        let start = Int(range[0])!, end = Int(range[1])!
        let snapshot = Self.state.withLock { $0.offsets.append(start); return $0 }
        if snapshot.failAt == start { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(snapshot.wrongRange ? start + 1 : start)-\(end)/\(snapshot.payload.count)",
                           "Content-Length": String(end - start + 1)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: snapshot.payload[start...end])
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
