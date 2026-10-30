import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct PlanLifecycleTests {
    @Test func editPersistsAndOriginalAgentRetryCannotOverwriteIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let transcript = try await fixture.transcribe(store)
        let source = transcript.source(for: try #require(transcript.spans.first))
        let operation = UUID()
        let original = try await store.savePlan(operationID: operation, title: "讨论安排", body: "周一确认。", sources: [source])
        let edited = try await store.editPlan(id: original.id, expectedRevision: 1, title: "修改后的安排", body: "周二确认。")
        #expect(edited.revision == 2)
        #expect(edited.sources == original.sources)
        let reopened = try fixture.store()
        #expect(try await reopened.plans().first?.body == "周二确认。")
        let url = try await reopened.planFileURL(id: original.id, expectedRevision: 2)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("周二确认。"))
        let replay = try await reopened.savePlan(operationID: operation, title: "讨论安排", body: "周一确认。", sources: [source])
        #expect(replay.revision == 2 && replay.body == edited.body)
        await #expect(throws: ArchiveError.stalePlan) {
            try await reopened.editPlan(id: original.id, expectedRevision: 1, title: "旧草稿", body: "不能覆盖。")
        }
        await #expect(throws: ArchiveError.stalePlan) { try await reopened.deletePlan(id: original.id, expectedRevision: 1) }
    }

    @Test func deletionPersistsATombstoneWithoutPlanText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let plan = try await store.savePlan(operationID: UUID(), title: "待删除", body: "私人计划正文", sources: [])
        let url = try await store.planFileURL(id: plan.id, expectedRevision: 1)
        try await store.deletePlan(id: plan.id, expectedRevision: 1)
        let reopened = try fixture.store()
        try await reopened.deletePlan(id: plan.id, expectedRevision: 1)
        try await reopened.projectPendingDocuments()
        #expect(try await reopened.plans().isEmpty)
        #expect(try await reopened.plan(operationID: plan.operationID) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: ArchiveError.planDeleted(plan.operationID)) {
            try await reopened.savePlan(operationID: plan.operationID, title: plan.title, body: plan.body, sources: [])
        }
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        let row = try #require(database.rows("SELECT length(document),state FROM plans WHERE id=?", [.text(plan.id.uuidString)]).first)
        #expect(row.integer(0) == 0 && row.string(1) == "deleted")
    }

    @Test func externalFileChangesCannotBeOverwrittenByEditorOrRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let plan = try await store.savePlan(operationID: UUID(), title: "文件冲突", body: "原内容", sources: [])
        let url = try await store.planFileURL(id: plan.id, expectedRevision: 1)
        try Data("外部编辑内容".utf8).write(to: url)
        await #expect(throws: ArchiveError.projectionConflict) {
            try await store.editPlan(id: plan.id, expectedRevision: 1, title: "新标题", body: "新内容")
        }
        await #expect(throws: ArchiveError.projectionConflict) {
            try await store.savePlan(operationID: plan.operationID, title: plan.title, body: plan.body, sources: [])
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "外部编辑内容")
        try FileManager.default.removeItem(at: url)
        await #expect(throws: ArchiveError.projectionConflict) {
            try await store.savePlan(operationID: plan.operationID, title: plan.title, body: plan.body, sources: [])
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func revisedSourceInvalidatesAnOpenPlanDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let transcript = try await fixture.transcribe(store)
        let plan = try await store.savePlan(operationID: UUID(), title: "原计划", body: "原内容",
            sources: [transcript.source(for: try #require(transcript.spans.first))])
        _ = try await store.reviseTranscript(sessionID: transcript.sessionID, expectedVersion: transcript.version, spans: transcript.spans)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.editPlan(id: plan.id, expectedRevision: plan.revision, title: "新计划", body: "旧草稿")
        }
        #expect(try await store.plans().isEmpty)
    }

    @Test func pendingEditProjectionRecoversAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let plan = try await store.savePlan(operationID: UUID(), title: "初版", body: "原内容", sources: [])
        let url = try await store.planFileURL(id: plan.id, expectedRevision: 1)
        let previousHash = try ContentHash.sha256(fileAt: url)
        let edited = PlanDocument(id: plan.id, operationID: plan.operationID, title: "第二版", body: "已提交，待投影",
            sources: [], createdAt: plan.createdAt, revision: 2, updatedAt: Date())
        // Emulate process exit after the SQLite commit but before replacing the Markdown projection.
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        try database.execute("UPDATE plans SET document=?,revision=2,state='pending',projection_hash=? WHERE id=?",
            [.blob(try WireJSON.encode(edited)), .text(previousHash), .text(plan.id.uuidString)])
        let reopened = try fixture.store()
        try await reopened.projectPendingDocuments()
        #expect(try await reopened.plans().first?.revision == 2)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(edited.body))
        try await reopened.projectPendingDocuments()
        #expect(try await reopened.plans().count == 1)
    }

    @Test func planProjectionRejectsASymbolicLinkAndLegacyDocumentDecodes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let plan = try await store.savePlan(operationID: UUID(), title: "链接检查", body: "原内容", sources: [])
        let url = try await store.planFileURL(id: plan.id, expectedRevision: 1)
        let outside = fixture.root.appendingPathComponent("outside.md")
        try Data("保持原样".utf8).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        await #expect(throws: ArchiveError.invalidQuery) { try await store.deletePlan(id: plan.id, expectedRevision: 1) }
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.editPlan(id: plan.id, expectedRevision: 1, title: "新标题", body: "新内容")
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "保持原样")
        var legacy = try #require(JSONSerialization.jsonObject(with: WireJSON.encode(plan)) as? [String: Any])
        legacy.removeValue(forKey: "revision")
        legacy.removeValue(forKey: "updatedAt")
        let decoded = try WireJSON.decode(PlanDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.revision == 1 && decoded.updatedAt == decoded.createdAt)
    }

    @Test func conflictingPendingPlanDoesNotBlockHealthyProjectionOrDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let conflict = try await store.savePlan(operationID: UUID(), title: "冲突", body: "原稿", sources: [])
        let conflictURL = try await store.planFileURL(id: conflict.id, expectedRevision: 1)
        let healthy = try await store.savePlan(operationID: UUID(), title: "健康", body: "旧版", sources: [])
        let healthyURL = try await store.planFileURL(id: healthy.id, expectedRevision: 1)
        let deleted = try await store.savePlan(operationID: UUID(), title: "清理", body: "正文", sources: [])
        let deletedURL = try await store.planFileURL(id: deleted.id, expectedRevision: 1)
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        for plan in [conflict, healthy] {
            let edited = PlanDocument(id: plan.id, operationID: plan.operationID, title: plan.title, body: "新版",
                sources: [], createdAt: plan.createdAt, revision: 2, updatedAt: Date())
            try database.execute("UPDATE plans SET document=?,revision=2,state='pending' WHERE id=?",
                [.blob(try WireJSON.encode(edited)), .text(plan.id.uuidString)])
        }
        try database.execute("UPDATE plans SET state='deleted',document=X'' WHERE id=?", [.text(deleted.id.uuidString)])
        try Data("外部修改".utf8).write(to: conflictURL)
        let reopened = try fixture.store()
        await #expect(throws: ArchiveError.projectionConflict) { try await reopened.projectPendingDocuments() }
        #expect(try String(contentsOf: healthyURL, encoding: .utf8).contains("新版"))
        #expect(try String(contentsOf: conflictURL, encoding: .utf8) == "外部修改")
        #expect(!FileManager.default.fileExists(atPath: deletedURL.path))
        #expect(try await reopened.plans().map(\.id) == [healthy.id])
    }
}
