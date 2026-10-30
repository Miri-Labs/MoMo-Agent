import Foundation

enum RecordingFileProtection {
    static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    static func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
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
        apply(to: url)
    }

    static func apply(to url: URL) {
        #if os(iOS) || os(watchOS)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    static func applyToSQLiteFiles(at databaseURL: URL) {
        apply(to: databaseURL)
        apply(to: URL(fileURLWithPath: databaseURL.path + "-wal"))
        apply(to: URL(fileURLWithPath: databaseURL.path + "-shm"))
        apply(to: URL(fileURLWithPath: databaseURL.path + "-journal"))
    }
}
