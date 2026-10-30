import CSQLite
import Foundation

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
}

struct RecordingDatabaseError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "Recording database (\(code)): \(message)" }
}

// Owned by RecordingStore; statements and transactions never cross an await.
final class RecordingDatabase {
    private let connection: OpaquePointer
    private(set) var changedChunkRows: Set<Int64> = []

    func acknowledgeChunkChanges() { changedChunkRows.removeAll(keepingCapacity: true) }

    init(url: URL) throws {
        var pointer: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS) || os(watchOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        let status = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot allocate SQLite connection"
            if let pointer { sqlite3_close(pointer) }
            throw RecordingDatabaseError(code: status, message: message)
        }
        connection = pointer
        sqlite3_busy_timeout(connection, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        RecordingFileProtection.applyToSQLiteFiles(at: url)
        sqlite3_update_hook(connection, { context, _, _, table, rowID in
            guard let context, let table, String(cString: table) == "chunks" else { return }
            let owner = Unmanaged<RecordingDatabase>.fromOpaque(context).takeUnretainedValue()
            owner.changedChunkRows.insert(rowID)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        sqlite3_update_hook(connection, nil, nil)
        sqlite3_close(connection)
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try rows(sql, values) { _ in () }
    }

    @discardableResult
    func rows<T>(_ sql: String, _ values: [SQLValue] = [], read: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        guard let statement else { throw RecordingDatabaseError(code: SQLITE_ERROR, message: "Empty statement") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let status: Int32
            switch value {
            case .text(let value): status = sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .real(let value): status = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            try check(status)
        }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { try check(status); return result }
            result.append(try read(statement))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            let original = error
            // FULL/I/O failures may have already rolled back the transaction.
            if sqlite3_get_autocommit(connection) == 0 {
                do { try execute("ROLLBACK") }
                catch { throw RecordingDatabaseError(code: SQLITE_ERROR, message: "Transaction failed: \(original); rollback failed: \(error)") }
            }
            throw original
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(row, column) else { return "" }
        return String(cString: text)
    }

    static func data(_ row: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard let bytes = sqlite3_column_blob(row, column), count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else {
            throw RecordingDatabaseError(code: status, message: String(cString: sqlite3_errmsg(connection)))
        }
    }
}
