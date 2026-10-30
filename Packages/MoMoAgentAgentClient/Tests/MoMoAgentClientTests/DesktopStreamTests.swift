import Foundation
import XCTest
@testable import MoMoAgentClient

final class DesktopStreamTests: XCTestCase, @unchecked Sendable {
    func testVideoAnswerMustMatchOfferNonceAndVersion() async throws {
        let offer = DesktopVideoSignal(sdp: "synthetic-offer")
        for mode in ["ok", "nonce", "version", "large"] {
            let route = VideoSignalFixture(mode: mode)
            let client = try AgentClient(baseURL: URL(string: "http://100.64.0.1:8767")!, credential: "synthetic", assistantID: UUID(), transport: route)
            do {
                let answer = try await client.desktopVideoOffer(offer)
                XCTAssertEqual(mode, "ok"); XCTAssertEqual(answer.nonce, offer.nonce)
            } catch AgentClientError.invalidResponse { XCTAssertNotEqual(mode, "ok") }
        }
    }
    private func packet(_ bytes: [UInt8]) -> Data {
        Data("--momo-frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(bytes.count)\r\nX-Frame-Sequence: 1\r\nX-Stream-ID: 00000000-0000-0000-0000-000000000001\r\n\r\n".utf8) + Data(bytes) + Data([13, 10])
    }
    func testEveryByteBoundaryAndCoalescedPictures() throws {
        let jpeg: [UInt8] = [255, 216, 0, 10, 13, 255, 217]
        let bytes = packet(jpeg) + packet(jpeg)
        for split in 0...bytes.count {
            var parser = DesktopJPEGParser()
            let first = try parser.append(Data(bytes.prefix(split)))
            let last = try parser.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual((first + last).map(\.jpeg), [Data(jpeg), Data(jpeg)])
        }
        var parser = DesktopJPEGParser(); var frames: [DesktopPicture] = []
        for byte in bytes { frames += try parser.append(Data([byte])) }
        XCTAssertEqual(frames.count, 2)
    }
    func testOversizeAndCorruptPicturesAreRejectedBeforePresentation() throws {
        var parser = DesktopJPEGParser()
        XCTAssertThrowsError(try parser.append(Data("--momo-frame\r\nContent-Type: image/jpeg\r\nContent-Length: 99999999\r\n\r\n".utf8)))
        parser = DesktopJPEGParser()
        XCTAssertThrowsError(try parser.append(packet([255, 216, 0, 1, 2])))
        parser = DesktopJPEGParser()
        XCTAssertThrowsError(try parser.append(Data(repeating: 32, count: 513)))
    }
    func testOldServerWithoutStreamCapabilityStillDecodes() throws {
        let status = try JSONDecoder().decode(DesktopStatus.self, from: Data(#"{"approved":true,"screen":true,"input":true,"owner":"agent","active":false,"epoch":0}"#.utf8))
        XCTAssertNil(status.preview_stream)
    }
    func testChunkDelegateDeliversWholeBytesAndCancelsAnOpenStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PictureHTTPStub.self]
        let stream = try await AgentHTTPStream.open(URLRequest(url: URL(string: "http://127.0.0.1/frames")!), configuration: configuration)
        XCTAssertEqual(stream.contentType, "multipart/x-mixed-replace")
        var iterator = stream.chunks.makeAsyncIterator()
        let chunk = try await iterator.next()
        XCTAssertEqual(chunk?.count, 256 * 1024)
        stream.cancel()
        do { _ = try await iterator.next(); XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    func testPrivatePreviewNeverFallsBackToOrdinaryNetwork() async throws {
        let client = try AgentClient(baseURL: URL(string: "http://100.64.0.1:8767")!, credential: "synthetic", assistantID: UUID(), transport: ClosedPrivateRoute())
        do {
            for try await _ in client.desktopFrames() { XCTFail("No frame expected") }
            XCTFail("Expected unavailable private route")
        } catch URLError.notConnectedToInternet { }
    }
}

private struct ClosedPrivateRoute: AgentTransport {
    let requiresExclusiveRouting = true
    func open(_ request: URLRequest) async throws -> AgentByteStream? { nil }
}

private final class PictureHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "multipart/x-mixed-replace; boundary=momo-frame"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 256 * 1024))
        // Remain open until the consumer cancels, like a live desktop stream.
    }
    override func stopLoading() {}
}

private struct VideoSignalFixture: AgentTransport {
    let mode: String
    let requiresExclusiveRouting = true
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        XCTAssertEqual(request.url?.path, "/desktop/v2/offer")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
        let offer = try JSONDecoder().decode(DesktopVideoSignal.self, from: request.httpBody!)
        let answer: [String: Any] = ["version": mode == "version" ? 2 : 1,
            "nonce": (mode == "nonce" ? UUID() : offer.nonce).uuidString,
            "sdp": mode == "large" ? String(repeating: "x", count: 131073) : "synthetic-answer"]
        let data = try JSONSerialization.data(withJSONObject: answer)
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}
