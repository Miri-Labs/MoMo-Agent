import Foundation

enum ArchiveFilePolicy {
    static func prepareDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        try apply(to: url)
    }

    static func apply(to url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ArchiveError.invalidQuery }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        #if canImport(Darwin)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var fileURL = url
        try fileURL.setResourceValues(excluded)
        #endif
    }

    static func prepareTree(_ directory: URL) throws {
        try prepareDirectory(directory)
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Files can contain a user-created link. Do not follow it or prevent other records opening.
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { try prepareTree(child) }
            else { try apply(to: child) }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
        // Atomic replacement can discard resource values, so set them on the resulting file.
        try apply(to: url)
    }
}
