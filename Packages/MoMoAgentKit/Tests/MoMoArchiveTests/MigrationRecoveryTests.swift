import CSQLite
import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct MigrationRecoveryTests {
    /// Each version is its own transaction. Later failure must retain earlier committed steps.
    @Test(arguments: MigrationFault.allCases)
    func schemaFiveFailurePreservesDataAndResumes(fault: MigrationFault) async throws {
        let fixture = try Fixture()
        let second = try Fixture()
        defer { fixture.remove(); second.remove() }
        let expected = try await prepareLegacyArchive(fixture, second: second)
        let databaseURL = fixture.root.appendingPathComponent("Library/Library/Application Support/MoMoAgent/archive.sqlite")
        let baseline = try withSQLite(databaseURL, readOnly: true) { connection in
            #expect(try connection.rows("PRAGMA user_version") == [["5"]])
            return try connection.snapshotLegacyTables()
        }
        let documentFiles = try fileHashes(under: expected.documentsURL)
        #expect(documentFiles.count >= 9)
        try withSQLite(databaseURL, readOnly: false) { try $0.execute(fault.installSQL) }

        // Both attempts execute the real ArchiveStore initializer; a second failed open must
        // neither advance the failed version nor leave partial DDL behind.
        for _ in 0..<2 {
            #expect(throws: ArchiveError.database(SQLITE_ERROR)) { _ = try fixture.store() }
            try withSQLite(databaseURL, readOnly: true) { connection in
                #expect(try connection.rows("PRAGMA user_version") == [[String(fault.lastCommittedVersion)]])
                try baseline.assertUnchanged(in: connection)
                #expect(try connection.rows("PRAGMA integrity_check") == [["ok"]])
                #expect(try connection.rows("PRAGMA foreign_key_check").isEmpty)
                try fault.assertMigrationBoundary(in: connection, expected: expected)
            }
            #expect(try fileHashes(under: expected.documentsURL) == documentFiles)
        }

        // Remove only the deliberately conflicting schema object. No migration, row repair,
        // version override, or file rewrite is performed by the test's SQLite connection.
        try withSQLite(databaseURL, readOnly: false) { try $0.execute(fault.removeSQL) }
        try await assertRecovered(fixture, expected: expected)
        try await assertRecovered(fixture, expected: expected)
        try withSQLite(databaseURL, readOnly: true) { connection in
            #expect(try connection.rows("PRAGMA user_version") == [["13"]])
            try baseline.assertUnchanged(in: connection)
            #expect(try connection.rows("PRAGMA integrity_check") == [["ok"]])
            #expect(try connection.rows("PRAGMA foreign_key_check").isEmpty)
            #expect(try connection.rows("SELECT count(*) FROM plans") == [["1"]])
        }
        #expect(try fileHashes(under: expected.documentsURL) == documentFiles)
    }
}

enum MigrationFault: CaseIterable, Sendable {
    case directoryIndex, batchTable, reconciliationIndex, processingFailures, processingTurns, transcriptPreview

    var lastCommittedVersion: Int {
        switch self { case .directoryIndex: 5; case .batchTable: 6; case .reconciliationIndex: 7; case .processingFailures: 8; case .processingTurns: 9; case .transcriptPreview: 10 }
    }
    var installSQL: String {
        switch self {
        case .directoryIndex: "CREATE INDEX session_document_directory ON metadata(value)"
        case .batchTable: "CREATE TABLE transcription_batch_ranges(test_fault INTEGER)"
        case .reconciliationIndex: "CREATE INDEX reconcile_pending ON metadata(value)"
        case .processingFailures: "CREATE TABLE processing_failures(test_fault INTEGER)"
        case .processingTurns: "CREATE TABLE processing_turns(test_fault INTEGER)"
        case .transcriptPreview: "ALTER TABLE sessions ADD COLUMN transcript_preview TEXT"
        }
    }
    var removeSQL: String {
        switch self {
        case .directoryIndex: "DROP INDEX session_document_directory"
        case .batchTable: "DROP TABLE transcription_batch_ranges"
        case .reconciliationIndex: "DROP INDEX reconcile_pending"
        case .processingFailures: "DROP TABLE processing_failures"
        case .processingTurns: "DROP TABLE processing_turns"
        case .transcriptPreview: "ALTER TABLE sessions DROP COLUMN transcript_preview"
        }
    }
    fileprivate func assertMigrationBoundary(in connection: MigrationSQLite, expected: LegacyArchive) throws {
        let sessionColumns = try connection.rows("PRAGMA table_info(sessions)").map { $0[1] }
        let planColumns = try connection.rows("PRAGMA table_info(plans)").map { $0[1] }
        let tables = try connection.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0[0] }
        let indexes = try connection.rows("SELECT name FROM sqlite_master WHERE type='index'").compactMap { $0[0] }
        #expect(sessionColumns.contains("document_directory") == (lastCommittedVersion >= 6))
        #expect(sessionColumns.contains("manifest_projected") == (lastCommittedVersion >= 6))
        #expect(planColumns.contains("revision") == (lastCommittedVersion >= 7))
        #expect(planColumns.contains("projection_hash") == (lastCommittedVersion >= 7))
        #expect(tables.contains("transcription_batches") == (lastCommittedVersion >= 7))
        #expect(tables.contains("transcription_batch_windows") == (lastCommittedVersion >= 7))
        #expect(tables.contains("transcription_batch_executions") == (lastCommittedVersion >= 7))
        #expect(indexes.contains("batch_windows_epoch") == (lastCommittedVersion >= 7))
        #expect(tables.contains("reconcile_requests") == (lastCommittedVersion >= 8))
        #expect(tables.contains("watch_status") == (lastCommittedVersion >= 8))
        if lastCommittedVersion >= 6 {
            let actual = try connection.rows("SELECT id,document_directory,manifest_projected FROM sessions ORDER BY id")
            let wanted = expected.recordings.sorted { $0.document.sessionID.uuidString < $1.document.sessionID.uuidString }
                .map { [$0.document.sessionID.uuidString, $0.directoryRelativePath, "1"] }
            #expect(actual == wanted)
        }
    }
}

private struct LegacyArchive {
    struct Recording {
        let document: TranscriptDocument
        let directoryRelativePath: String
    }
    let libraryID: UUID
    let documentsURL: URL
    let recordings: [Recording]
    let plan: PlanDocument
    let planURL: URL
}

private func prepareLegacyArchive(_ fixture: Fixture, second: Fixture) async throws -> LegacyArchive {
    let store = try fixture.store()
    let documents = [try await fixture.transcribe(store), try await second.transcribe(store)]
    try await store.projectPendingDocuments()
    let sources = documents.map { $0.source(for: $0.spans[0]) }
    let plan = try await store.savePlan(operationID: UUID(), title: "旧档案计划", body: "保留两份录音的计划与原音映射。", sources: sources)
    let planURL = try await store.planFileURL(id: plan.id, expectedRevision: plan.revision)
    var recordings: [LegacyArchive.Recording] = []
    for document in documents {
        let directory = try await store.transcriptDirectory(sessionID: document.sessionID)
        recordings.append(.init(document: document, directoryRelativePath: String(directory.path.dropFirst(store.rootURL.path.count + 1))))
    }
    let expected = LegacyArchive(libraryID: store.libraryInstanceID, documentsURL: store.rootURL.appendingPathComponent("Documents"), recordings: recordings, plan: plan, planURL: planURL)
    try await store.makeSchemaFiveFixture()
    return expected
}

private func assertRecovered(_ fixture: Fixture, expected: LegacyArchive) async throws {
    let store = try fixture.store()
    #expect(store.libraryInstanceID == expected.libraryID)
    #expect(try await store.recordings().count == 2)
    for recording in expected.recordings {
        let document = try await store.readTranscript(sessionID: recording.document.sessionID)
        #expect(try WireJSON.encode(document) == WireJSON.encode(recording.document))
        let directory = try await store.transcriptDirectory(sessionID: document.sessionID)
        #expect(directory == store.rootURL.appendingPathComponent(recording.directoryRelativePath, isDirectory: true))
        let lease = try await store.acquireAudioLease(source: document.source(for: document.spans[0]))
        #expect(try ContentHash.sha256(fileAt: lease.audioURL) == lease.manifest.audioSHA256)
        #expect(lease.audioURL.deletingLastPathComponent().deletingLastPathComponent().path == directory.path)
        await store.releaseAudioLease(id: lease.id)
    }
    #expect(try await store.recordingFileIssues().isEmpty)
    let plan = try #require(await store.plan(operationID: expected.plan.operationID))
    #expect(try WireJSON.encode(plan) == WireJSON.encode(expected.plan))
    #expect(try await store.planFileURL(id: plan.id, expectedRevision: plan.revision) == expected.planURL)
    // The formal idempotent write must recover the same plan rather than duplicate or replace it.
    let retry = try await store.savePlan(operationID: plan.operationID, title: plan.title, body: plan.body, sources: plan.sources)
    #expect(try WireJSON.encode(retry) == WireJSON.encode(expected.plan))
    #expect(try await store.plans().map(\.id) == [expected.plan.id])
}

private func fileHashes(under directory: URL) throws -> [String: String] {
    let entries = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: String] = [:]
    for case let url as URL in entries {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count + 1))] = try ContentHash.sha256(fileAt: url)
        }
    }
    return result
}

/// A separate SQLite connection inspects persisted state without running ArchiveDatabase.init.
/// It never contains any migration implementation; only fault installation/removal and queries.
private func withSQLite<T>(_ url: URL, readOnly: Bool, _ operation: (MigrationSQLite) throws -> T) throws -> T {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(url.path, &handle, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil)
    guard code == SQLITE_OK, let handle else {
        if let handle { sqlite3_close(handle) }
        throw ArchiveError.database(code)
    }
    defer { #expect(sqlite3_close(handle) == SQLITE_OK) }
    return try operation(MigrationSQLite(handle: handle))
}

private struct LegacyTableSnapshot {
    let queries: [String: [[String?]]]
    func assertUnchanged(in connection: MigrationSQLite) throws {
        for (query, expected) in queries { #expect(try connection.rows(query) == expected, "Legacy row changed: \(query)") }
    }
}

private struct MigrationSQLite {
    let handle: OpaquePointer
    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw ArchiveError.database(prepared) }
        defer { sqlite3_finalize(statement) }
        var output: [[String?]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            output.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw ArchiveError.database(code) }
        return output
    }
    func execute(_ sql: String) throws { _ = try rows(sql) }
    func snapshotLegacyTables() throws -> LegacyTableSnapshot {
        let tables = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        var queries: [String: [[String?]]] = [:]
        for table in tables {
            let name = try #require(table[0])
            let columns = try rows("PRAGMA table_info(\(quoted(name)))").map { try #require($0[1]) }
            let selection = columns.map { "quote(\(quoted($0)))" }.joined(separator: ",")
            let query = "SELECT \(selection) FROM \(quoted(name)) ORDER BY rowid"
            queries[query] = try rows(query)
        }
        return LegacyTableSnapshot(queries: queries)
    }
    private func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
