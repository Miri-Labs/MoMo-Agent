import Foundation
import XCTest
@testable import MoMoAgentClient

final class RecordingCitationTests: XCTestCase, @unchecked Sendable {
    private let session = "00000000-0000-0000-0000-000000000010"
    private let span = "00000000-0000-0000-0000-000000000011"
    private var url: URL { URL(string: "momoagent://source/\(session)/\(span)?version=78&generation=0")! }
    private var sourceID: String { "00000000-0000-0000-0000-000000000012/" + session }
    private var revision: String { "0:86:abc:0" }
    private func source(_ revision: String? = nil, id: String? = nil) -> [String: Any] {
        ["id": id ?? sourceID, "revision": revision ?? self.revision, "total_characters": 8000]
    }
    private func textPage(_ spans: [[String: Any]], offset: Int = 0, next: Int? = nil, revision: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["source_revision": revision ?? self.revision, "text": "测试原文", "offset": offset,
                                    "end": next ?? 8000, "total_characters": 8000, "spans": spans]
        if let next { result["next_offset"] = next }
        return result
    }
    private func client(_ replies: [[String: Any]]) throws -> (AgentClient, CitationTransport) {
        let transport = CitationTransport(try replies.map { try JSONSerialization.data(withJSONObject: $0) })
        return (try AgentClient(baseURL: URL(string: "http://127.0.0.1:8766")!, credential: "test-only",
                                assistantID: UUID(), transport: transport), transport)
    }
    private var target: [String: Any] { ["id": span, "text": "对应的录音原文", "recorded_at": 1000] }

    func testURLRejectsMalformedIdentityAndUnsafeVariants() {
        XCTAssertNotNil(RecordingCitation(url: url))
        for value in [url.absoluteString + "&version=1", url.absoluteString + "#other",
                      url.absoluteString.replacingOccurrences(of: "version=78", with: "version=+78"),
                      url.absoluteString.replacingOccurrences(of: "version=78", with: "version=9223372036854775808"),
                      url.absoluteString.replacingOccurrences(of: "source/", with: "user@source/"),
                      url.absoluteString.replacingOccurrences(of: "source/", with: "source:80/"),
                      url.absoluteString.replacingOccurrences(of: "generation=0", with: "generation=-1") ] {
            XCTAssertNil(RecordingCitation(url: URL(string: value)!), value)
        }
    }
    func testFindsOlderCitationAcrossBothSourceAndTextPagesAndMarksCurrentText() async throws {
        let (client, transport) = try client([
            ["items": [], "next_cursor": "second"], ["items": [source()]],
            textPage([], next: 4000), textPage([target], offset: 4000)
        ])
        let result = try await client.recordingCitation(RecordingCitation(url: url)!)
        XCTAssertEqual(result.span.text, "对应的录音原文")
        XCTAssertTrue(result.showsUpdatedTranscript)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/sources", "/v1/sources", "/v1/source", "/v1/source"])
        XCTAssertTrue(requests[3].url!.query!.contains("offset=4000"))
    }
    func testSameVersionDoesNotClaimAnUpdate() async throws {
        let rev = "0:78:abc:0"
        let (client, _) = try client([["items": [source(rev)]], textPage([target], revision: rev)])
        let result = try await client.recordingCitation(RecordingCitation(url: url)!)
        XCTAssertFalse(result.showsUpdatedTranscript)
    }
    func testMissingDeletedOrAmbiguousSourcesNeverSelectAnotherRecording() async throws {
        for sources in [[], [source(), source(id: "00000000-0000-0000-0000-000000000013/" + session)]] {
            let (client, _) = try client([["items": sources]])
            do { _ = try await client.recordingCitation(RecordingCitation(url: url)!); XCTFail("Must reject missing/ambiguous source") }
            catch is RecordingCitationError { }
        }
    }
    func testChangedGenerationFutureVersionAndMissingSpanFailClosed() async throws {
        for revision in ["1:86:abc:0", "0:77:abc:0", "0:86:abc:1", "invalid"] {
            let (client, transport) = try client([["items": [source(revision)]]])
            do { _ = try await client.recordingCitation(RecordingCitation(url: url)!); XCTFail("Must reject changed identity") }
            catch is RecordingCitationError { }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
        let (client, _) = try client([["items": [source()]], textPage([])])
        do { _ = try await client.recordingCitation(RecordingCitation(url: url)!); XCTFail("Must reject missing span") }
        catch is RecordingCitationError { }
    }
    func testRevisionChangesAndStuckPaginationDoNotReadUnrelatedTextOrLoop() async throws {
        for replies in [
            [["items": [source()]], textPage([target], revision: "0:87:def:0")],
            [["items": [source()]], textPage([], next: 0)],
            [["items": [], "next_cursor": "same"], ["items": [], "next_cursor": "same"]]
        ] {
            let (client, _) = try client(replies)
            do { _ = try await client.recordingCitation(RecordingCitation(url: url)!); XCTFail("Must reject inconsistent pages") }
            catch is RecordingCitationError { }
        }
    }
}

private actor CitationTransport: AgentTransport {
    nonisolated let requiresExclusiveRouting = true
    private var replies: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Data]) { self.replies = replies }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let data = replies.removeFirst()
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { continuation in
            continuation.yield(data); continuation.finish()
        })
    }
}
