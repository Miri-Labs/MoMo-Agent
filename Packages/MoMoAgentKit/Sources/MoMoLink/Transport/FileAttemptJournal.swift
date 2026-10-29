import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum FileAttemptJournal {
    static func load(at url: URL) throws -> (ledger: FileAttemptLedger, recoveredCorruption: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (FileAttemptLedger(), false) }
        let data = try Data(contentsOf: url)
        do { return (try JSONDecoder().decode(FileAttemptLedger.self, from: data), false) }
        catch is DecodingError {
            // This cache cannot authorize deletion. Preserve the evidence and rebuild only transport state.
            let backup = url.deletingPathExtension().appendingPathExtension("invalid-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
            var replacement = FileAttemptLedger()
            replacement.resetPeer() // Reject all old/legacy callbacks; re-observe outstanding files from zero age.
            try save(replacement, at: url)
            return (replacement, true)
        }
    }

    static func save(_ ledger: FileAttemptLedger, at url: URL) throws {
        try JSONEncoder().encode(ledger).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { handle.closeFile() }
        try handle.synchronize()
        #if canImport(Darwin)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        #endif
    }
}
