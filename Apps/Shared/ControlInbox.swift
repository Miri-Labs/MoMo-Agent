import Foundation
import MoMoContracts

/// The delegate persists control messages before returning to WatchConnectivity.
final class ControlInbox: Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            return
        }
        try data.write(to: destination, options: .atomic)
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
                try Data(next.utf8).write(to: position, options: .atomic)
            }
            return batch
        }
    }

    private func loadPendingLocked(limit: Int?, after cursor: String?) throws -> ControlInboxBatch {
            var messages: [ControlMessage] = []
            var failures: [String] = []
            let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let remaining = paths.filter { path in cursor.map { $0 < path.lastPathComponent } ?? true }
            let selected = Array(remaining.prefix(limit ?? remaining.count))
            for path in selected {
                do {
                    guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384 else {
                        throw ControlInboxError.oversizedMessage
                    }
                    let message = try WireJSON.decode(ControlMessage.self, from: Data(contentsOf: path))
                    guard path.lastPathComponent == fileURL(for: message).lastPathComponent else {
                        throw ControlInboxError.conflictingMessage
                    }
                    messages.append(message)
                } catch {
                    failures.append(String(localized: "设备同步消息 \(path.deletingPathExtension().lastPathComponent) 无法读取。"))
                }
            }
            return ControlInboxBatch(messages: messages, failures: failures,
                scannedThrough: selected.last?.lastPathComponent, hasMore: remaining.count > selected.count)
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
}

struct ControlInboxBatch: Sendable {
    let messages: [ControlMessage]
    let failures: [String]
    var scannedThrough: String? = nil
    var hasMore = false
}

enum ControlInboxError: Error { case conflictingMessage, oversizedMessage, damagedMessage, invalidLimit }
