import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct PlanCleanupIsolationTests {
    @Test(arguments: [false, true], [false, true])
    func invalidPlanPathDoesNotBlockOtherPlansOrRecordingDeletion(
        deletedPlan: Bool, symbolicLink: Bool
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let transcript = try await fixture.transcribe(store)
        let source = transcript.source(for: try #require(transcript.spans.first))
        let broken = try await store.savePlan(operationID: UUID(), title: "损坏路径", body: "等待清理", sources: [source])
        let brokenURL = try await store.planFileURL(id: broken.id, expectedRevision: 1)
        if deletedPlan { try await store.deletePlan(id: broken.id, expectedRevision: 1) }
        let healthy = try await store.savePlan(operationID: UUID(), title: "正常计划", body: "应当删除", sources: [source])
        let healthyURL = try await store.planFileURL(id: healthy.id, expectedRevision: 1)
        let recordingDirectory = try await store.transcriptDirectory(sessionID: transcript.sessionID)
        let outside = fixture.root.appendingPathComponent("outside.md")
        let outsideBytes = Data("不能删除链接目标或未知目录内容".utf8)
        try outsideBytes.write(to: outside)
        if FileManager.default.fileExists(atPath: brokenURL.path) { try FileManager.default.removeItem(at: brokenURL) }
        let preservedURL: URL
        if symbolicLink {
            try FileManager.default.createSymbolicLink(at: brokenURL, withDestinationURL: outside)
            preservedURL = outside
        } else {
            try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: false)
            preservedURL = brokenURL.appendingPathComponent("foreign.md")
            try outsideBytes.write(to: preservedURL)
        }

        await #expect(throws: ArchiveError.invalidQuery) { try await store.deleteSession(id: transcript.sessionID) }
        #expect(!FileManager.default.fileExists(atPath: healthyURL.path))
        #expect(!FileManager.default.fileExists(atPath: recordingDirectory.path))
        #expect(try Data(contentsOf: preservedURL) == outsideBytes)
        #expect(try Data(contentsOf: outside) == outsideBytes)
        #expect(try await store.plans().isEmpty)
        #expect(try await store.pendingDeletions().map(\.sessionID) == [transcript.sessionID])

        let reopened = try fixture.store()
        await #expect(throws: ArchiveError.invalidQuery) { try await reopened.cleanDeletedFiles() }
        #expect(try Data(contentsOf: preservedURL) == outsideBytes)
        #expect(!FileManager.default.fileExists(atPath: healthyURL.path))
        #expect(!FileManager.default.fileExists(atPath: recordingDirectory.path))
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        let deletion = try #require(database.rows("SELECT files_cleaned FROM deletions WHERE session_id=?", [.text(transcript.sessionID.uuidString)]).first)
        #expect(deletion.integer(0) == 1)
        let tombstone = try #require(database.rows("SELECT state,length(document) FROM plans WHERE id=?", [.text(broken.id.uuidString)]).first)
        #expect(tombstone.string(0) == (deletedPlan ? "deleted" : "invalidated"))
        #expect(tombstone.integer(1) == 0)

        // Remove only the fixture's rejected path; the persisted cleanup can then finish normally.
        try FileManager.default.removeItem(at: brokenURL)
        try await reopened.cleanDeletedFiles()
        #expect(try Data(contentsOf: outside) == outsideBytes)
        #expect(try await reopened.plans().isEmpty)
    }
}
