import Foundation
import MoMoContracts

extension ArchiveStore {
    public func savePlan(operationID: UUID, title: String, body: String, sources: [SourceReference]) throws -> PlanDocument {
        try validatePlanInput(title: title, body: body)
        let input = PlanInput(title: title, body: body, sources: sources)
        let hash = ContentHash.sha256(try WireJSON.encode(input))
        let document: PlanDocument = try database.transaction {
            try validateSources(sources)
            if let row = try database.rows("SELECT input_hash,document,state FROM plans WHERE operation_id=?", [.text(operationID.uuidString)]).first {
                guard row.string(0) == hash else { throw ArchiveError.operationConflict(operationID) }
                guard row.string(2) != "invalidated" else { throw ArchiveError.staleSource }
                guard row.string(2) != "deleted" else { throw ArchiveError.planDeleted(operationID) }
                return try WireJSON.decode(PlanDocument.self, from: row.requireData(1))
            }
            let plan = PlanDocument(id: UUID(), operationID: operationID, title: title, body: body, sources: sources, createdAt: Date())
            try database.execute("INSERT INTO plans(id,operation_id,input_hash,document) VALUES(?,?,?,?)", [.text(plan.id.uuidString), .text(operationID.uuidString), .text(hash), .blob(try WireJSON.encode(plan))])
            for id in Set(sources.map(\.sessionID)) {
                try database.execute("INSERT INTO plan_sources(plan_id,session_id) VALUES(?,?)", [.text(plan.id.uuidString), .text(id.uuidString)])
            }
            #if DEBUG && os(macOS)
            planBoundaryObserver?(.transactionBeforeCommit)
            #endif
            return plan
        }
        #if DEBUG && os(macOS)
        planBoundaryObserver?(.committedBeforeProjection)
        #endif
        try projectPlan(document)
        return document
    }

    public func plan(operationID: UUID) throws -> PlanDocument? {
        guard let row = try database.rows("SELECT document FROM plans WHERE operation_id=? AND state IN ('pending','ready')", [.text(operationID.uuidString)]).first else { return nil }
        let plan = try WireJSON.decode(PlanDocument.self, from: row.requireData(0))
        try validateSources(plan.sources)
        return plan
    }

    public func plans(limit: Int = 50) throws -> [PlanDocument] {
        guard (1...200).contains(limit) else { throw ArchiveError.invalidQuery }
        return try database.rows("SELECT document FROM plans WHERE state='ready' ORDER BY rowid DESC LIMIT ?", [.integer(Int64(limit))]).map { row in
            let plan = try WireJSON.decode(PlanDocument.self, from: row.requireData(0))
            try validateSources(plan.sources)
            return plan
        }
    }

    /// User edits retain the original operation identity, so a delayed Agent retry cannot undo them.
    public func editPlan(id: UUID, expectedRevision: Int64, title: String, body: String) throws -> PlanDocument {
        try validatePlanInput(title: title, body: body)
        let edited: PlanDocument = try database.transaction {
            let current = try existingPlan(id: id, expectedRevision: expectedRevision)
            try validateSources(current.sources)
            let url = planURL(id: id)
            try validatePlanPath(url)
            guard files.fileExists(atPath: url.path), try readPlanData(url) == planData(current) else {
                throw ArchiveError.projectionConflict
            }
            let edited = PlanDocument(id: current.id, operationID: current.operationID, title: title, body: body,
                sources: current.sources, createdAt: current.createdAt, revision: current.revision + 1, updatedAt: Date())
            try database.execute("UPDATE plans SET document=?,revision=?,state='pending',projection_hash=? WHERE id=?",
                [.blob(try WireJSON.encode(edited)), .integer(edited.revision), .text(ContentHash.sha256(planData(current))), .text(id.uuidString)])
            return edited
        }
        try projectPlan(edited)
        return edited
    }

    public func deletePlan(id: UUID, expectedRevision: Int64) throws {
        try database.transaction {
            if try database.rows("SELECT state FROM plans WHERE id=?", [.text(id.uuidString)]).first?.string(0) == "deleted" { return }
            _ = try existingPlan(id: id, expectedRevision: expectedRevision)
            try validatePlanPath(planURL(id: id))
            // Keep only the operation tombstone; retries must not recreate deleted content.
            try database.execute("UPDATE plans SET state='deleted',document=X'',projection_hash=NULL,files_cleaned=0 WHERE id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM plan_sources WHERE plan_id=?", [.text(id.uuidString)])
        }
        hasPendingFileDeletions = true
        try cleanDeletedPlanFiles()
    }

    public func planFileURL(id: UUID, expectedRevision: Int64) throws -> URL {
        let current = try existingPlan(id: id, expectedRevision: expectedRevision)
        try validateSources(current.sources)
        let url = planURL(id: id)
        try validatePlanPath(url)
        guard files.fileExists(atPath: url.path), try readPlanData(url) == planData(current) else {
            throw ArchiveError.projectionConflict
        }
        return url
    }

    private func existingPlan(id: UUID, expectedRevision: Int64) throws -> PlanDocument {
        guard let row = try database.rows("SELECT document,state,revision FROM plans WHERE id=?", [.text(id.uuidString)]).first else { throw ArchiveError.missingPlan(id) }
        guard row.string(1) != "deleted" else { throw ArchiveError.planDeleted(id) }
        guard row.string(1) != "invalidated" else { throw ArchiveError.staleSource }
        guard row.integer(2) == expectedRevision else { throw ArchiveError.stalePlan }
        return try WireJSON.decode(PlanDocument.self, from: row.requireData(0))
    }

    func cleanDeletedPlanFiles() throws {
        var firstFailure: (any Error)?
        var candidateIDs: Set<String> = []
        for row in try database.rows("SELECT id FROM plans WHERE state IN ('invalidated','deleted') AND files_cleaned=0") {
            candidateIDs.insert(try row.requireString(0))
        }
        let plansDir = rootURL.appendingPathComponent("Documents/workspace/plans")
        if let entries = try? files.contentsOfDirectory(atPath: plansDir.path), !entries.isEmpty {
            let diskIDs = entries.compactMap { entry -> String? in
                guard entry.hasSuffix(".md") else { return nil }
                let stem = String(entry.dropLast(3))
                return UUID(uuidString: stem)?.uuidString
            }
            if !diskIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: diskIDs.count).joined(separator: ",")
                for row in try database.rows(
                    "SELECT id FROM plans WHERE state IN ('invalidated','deleted') AND id IN (\(placeholders))",
                    diskIDs.map(SQLValue.text)
                ) {
                    candidateIDs.insert(try row.requireString(0))
                }
            }
        }
        for idString in candidateIDs.sorted() {
            do {
                guard let id = UUID(uuidString: idString) else { continue }
                let url = planURL(id: id)
                try validatePlanPath(url)
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                try database.execute("UPDATE plans SET files_cleaned=1 WHERE id=?", [.text(idString)])
            } catch {
                try? database.execute("UPDATE plans SET files_cleaned=0 WHERE id=?", [.text(idString)])
                hasPendingFileDeletions = true
                // Keep the failed tombstone for retry without blocking unrelated deletions.
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func validatePlanInput(title: String, body: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 262_144 else { throw ArchiveError.invalidQuery }
    }

    func planURL(id: UUID) -> URL { rootURL.appendingPathComponent("Documents/workspace/plans/\(id.uuidString).md") }

    private func validatePlanPath(_ url: URL) throws {
        let base = rootURL.standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(base.appendingPathComponent("Documents/workspace/plans").path + "/") else { throw ArchiveError.invalidQuery }
        var cursor = base
        let parts = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1)).split(separator: "/")
        for (index, part) in parts.enumerated() {
            cursor.appendPathComponent(String(part))
            do {
                let type = try files.attributesOfItem(atPath: cursor.path)[.type] as? FileAttributeType
                guard index == parts.count - 1 ? type == .typeRegular : type == .typeDirectory else { throw ArchiveError.invalidQuery }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        }
    }

    private func planData(_ plan: PlanDocument) -> Data {
        let text = "# \(plan.title)\n\n<!-- momoagent plan=\(plan.id.uuidString) operation=\(plan.operationID.uuidString) -->\n\n\(plan.body)\n\n## 来源\n\n" + plan.sources.map { "- \($0.sessionID.uuidString) / \($0.spanID.uuidString) / v\($0.transcriptVersion)\n" }.joined()
        return Data(text.utf8)
    }

    private func readPlanData(_ url: URL) throws -> Data {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576 else {
            throw ArchiveError.projectionConflict
        }
        return try Data(contentsOf: url)
    }

    func projectPlan(_ plan: PlanDocument) throws {
        try validateSources(plan.sources)
        let url = planURL(id: plan.id)
        try validatePlanPath(url)
        _ = try existingPlan(id: plan.id, expectedRevision: plan.revision)
        guard let projection = try database.rows("SELECT state,projection_hash FROM plans WHERE id=?", [.text(plan.id.uuidString)]).first else { throw ArchiveError.missingPlan(plan.id) }
        let data = planData(plan)
        if files.fileExists(atPath: url.path) {
            let existing = try readPlanData(url)
            guard existing == data || (projection.string(0) == "pending" && projection.string(1) == ContentHash.sha256(existing)) else { throw ArchiveError.projectionConflict }
            if existing != data { try ArchiveFilePolicy.write(data, to: url) }
        } else {
            // Only new plans have no previous projection. An external deletion is not an invitation to recreate it.
            guard projection.string(0) == "pending", projection.string(1) == nil else { throw ArchiveError.projectionConflict }
            try ArchiveFilePolicy.prepareDirectory(url.deletingLastPathComponent())
            try ArchiveFilePolicy.write(data, to: url)
        }
        #if DEBUG && os(macOS)
        planBoundaryObserver?(.projectionBeforeReady)
        #endif
        try database.execute("UPDATE plans SET state='ready',projection_hash=? WHERE id=?", [.text(ContentHash.sha256(data)), .text(plan.id.uuidString)])
    }
}

private struct PlanInput: Codable { let title: String; let body: String; let sources: [SourceReference] }
