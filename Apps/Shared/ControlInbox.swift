import Darwin
import Foundation
import MoMoContracts

/// The delegate persists control messages before returning to WatchConnectivity.
final class ControlInbox: Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try Self.createProtectedDirectory(at: directory, withIntermediateDirectories: true)
    }

    func preserve(_ message: ControlMessage) throws {
        try lock.withLock { try preserveLocked(message) }
    }

    private func preserveLocked(_ message: ControlMessage) throws {
        let data = try WireJSON.encode(message)
        guard data.count <= 16_384 else { throw ControlInboxError.oversizedMessage }
        let destination = fileURL(for: message)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw ControlInboxError.conflictingMessage }
            Self.applyProtection(to: destination)
            return
        }
        try data.write(to: destination, options: Self.atomicWriteOptions)
        Self.applyProtection(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try handle.close()
            throw error
        }
    }

    func pending() throws -> [ControlMessage] {
        let batch = try loadPending()
        guard batch.failures.isEmpty else { throw ControlInboxError.damagedMessage }
        return batch.messages
    }

    func hasPending() throws -> Bool {
        try lock.withLock {
            guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw ControlInboxError.damagedMessage }
            for case let path as URL in entries where path.pathExtension == "json" { return true }
            return false
        }
    }

    func loadPending(limit: Int? = nil, after cursor: String? = nil) throws -> ControlInboxBatch {
        guard limit.map({ (1...32).contains($0) }) ?? true else { throw ControlInboxError.invalidLimit }
        return try lock.withLock { try loadPendingLocked(limit: limit, after: cursor) }
    }

    /// A durable scan position prevents an unprocessable old message starving later replies after a cold wake.
    func loadBackgroundPage(limit: Int) throws -> ControlInboxBatch {
        guard (1...32).contains(limit) else { throw ControlInboxError.invalidLimit }
        return try lock.withLock {
            let position = directory.appendingPathComponent(".background-position")
            let hasPosition = FileManager.default.fileExists(atPath: position.path)
            let cursor = hasPosition
                ? String(decoding: try Data(contentsOf: position), as: UTF8.self) : ""
            let batch = try loadPendingLocked(limit: limit, after: cursor.isEmpty ? nil : cursor)
            let next = batch.hasMore ? (batch.scannedThrough ?? "") : ""
            if !hasPosition || next != cursor {
                try Data(next.utf8).write(to: position, options: Self.atomicWriteOptions)
                Self.applyProtection(to: position)
            }
            return batch
        }
    }

    private struct RankedEntry {
        let rank: Int
        let filename: String
        let sortKey: String
        let message: ControlMessage
    }

    private func loadPendingLocked(limit: Int?, after cursor: String?) throws -> ControlInboxBatch {
        pruneExpiredQuarantineLocked()
        var valid: [RankedEntry] = []
        var failures: [String] = []
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for path in paths {
            do {
                var info = stat()
                guard lstat(path.path, &info) == 0,
                      (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      info.st_size <= 16_384 else {
                    throw ControlInboxError.oversizedMessage
                }
                let message = try WireJSON.decode(ControlMessage.self, from: Data(contentsOf: path))
                let filename = path.lastPathComponent
                guard filename == fileURL(for: message).lastPathComponent else {
                    throw ControlInboxError.conflictingMessage
                }
                let rank = Self.priorityRank(for: message)
                valid.append(RankedEntry(rank: rank, filename: filename, sortKey: "\(rank):\(filename)", message: message))
            } catch {
                quarantineCorruptFileLocked(path)
                failures.append(String(localized: "设备同步消息 \(path.deletingPathExtension().lastPathComponent) 无法读取。"))
            }
        }

        valid.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.filename < rhs.filename
        }

        let remaining = valid.filter { entry in
            Self.isAfterCursor(entryRank: entry.rank, filename: entry.filename, cursor: cursor)
        }
        let selected = Array(remaining.prefix(limit ?? remaining.count))
        return ControlInboxBatch(
            messages: selected.map(\.message),
            failures: failures,
            scannedThrough: selected.last?.sortKey,
            hasMore: remaining.count > selected.count
        )
    }

    private static func priorityRank(for message: ControlMessage) -> Int {
        switch message {
        case .deleteSession, .deleteApplied:
            return 0
        case .receiverIdentity:
            return 1
        case .reconcileRequest, .reconcileResponse:
            return 2
        case .receipt, .receiptApplied, .epochEnded, .epochInterrupted, .captureMark:
            return 3
        }
    }

    private static func isAfterCursor(entryRank: Int, filename: String, cursor: String?) -> Bool {
        guard let cursor, !cursor.isEmpty else { return true }
        let parsed = parseCursor(cursor)
        if let cursorRank = parsed.rank {
            if entryRank < cursorRank { return true }
            if entryRank == cursorRank { return filename > parsed.filename }
            return true
        }
        if entryRank < 3 { return true }
        return filename > parsed.filename
    }

    private static func parseCursor(_ cursor: String) -> (rank: Int?, filename: String) {
        let bytes = Array(cursor.utf8)
        if bytes.count > 2, bytes[1] == UInt8(ascii: ":"), bytes[0] >= UInt8(ascii: "0"), bytes[0] <= UInt8(ascii: "9") {
            let rank = Int(bytes[0] - UInt8(ascii: "0"))
            let filename = String(decoding: bytes.dropFirst(2), as: UTF8.self)
            return (rank, filename)
        }
        return (nil, cursor)
    }

    private func quarantineCorruptFileLocked(_ path: URL) {
        let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
        do {
            try Self.createProtectedDirectory(at: quarantine, withIntermediateDirectories: true)
            let preferred = quarantine.appendingPathComponent(path.lastPathComponent)
            let destination = FileManager.default.fileExists(atPath: preferred.path)
                ? quarantine.appendingPathComponent("\(UUID().uuidString)-\(path.lastPathComponent)")
                : preferred
            try FileManager.default.moveItem(at: path, to: destination)
            Self.applyProtection(to: destination)
        } catch {
            // Leave unreadable path untouched if quarantine destination itself cannot be written.
        }
    }

    private func pruneExpiredQuarantineLocked(retentionInterval: TimeInterval = 14 * 86_400) {
        let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
        var rootStat = stat()
        guard lstat(quarantine.path, &rootStat) == 0,
              (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              let children = try? FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil) else {
            return
        }
        let now = Date().timeIntervalSince1970
        for child in children {
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            if modified > 0, now - modified > retentionInterval {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    func remove(_ message: ControlMessage) throws {
        try lock.withLock {
            let path = fileURL(for: message)
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            guard try Data(contentsOf: path) == WireJSON.encode(message) else { throw ControlInboxError.conflictingMessage }
            try FileManager.default.removeItem(at: path)
        }
    }

    private func fileURL(for message: ControlMessage) -> URL {
        let id: UUID
        switch message {
        case .receiverIdentity(let value): id = value.messageID
        case .epochEnded(let value): id = value.messageID
        case .epochInterrupted(let value): id = value.messageID
        case .captureMark(let value): id = value.messageID
        case .receipt(let value): id = value.messageID
        case .receiptApplied(let value): id = value.messageID
        case .deleteSession(let value): id = value.messageID
        case .deleteApplied(let value): id = value.messageID
        case .reconcileRequest(let value): id = value.messageID
        case .reconcileResponse(let value): id = value.messageID
        }
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    private static func createProtectedDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        #if os(iOS) || os(watchOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: intermediates,
            attributes: attributes
        )
        applyProtection(to: url)
    }

    private static func applyProtection(to url: URL) {
        #if os(iOS) || os(watchOS)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

struct ControlInboxBatch: Sendable {
    let messages: [ControlMessage]
    let failures: [String]
    var scannedThrough: String? = nil
    var hasMore = false
}

enum ControlInboxError: Error { case conflictingMessage, oversizedMessage, damagedMessage, invalidLimit }
