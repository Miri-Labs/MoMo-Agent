import Foundation

enum ArchiveFilePolicy {
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }

    @discardableResult
    static func prepareDirectory(_ url: URL) throws -> Bool {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        return try apply(to: url)
    }

    @discardableResult
    static func apply(to url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ArchiveError.invalidQuery }
        var applied = true
        #if os(iOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch where isPermissionDenied(error) {
            applied = false
        }
        #endif
        #if canImport(Darwin)
        do {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var fileURL = url
            try fileURL.setResourceValues(excluded)
        } catch where isPermissionDenied(error) {
            applied = false
        }
        #endif
        return applied
    }

    static func prepareTree(_ directory: URL) throws {
        _ = try repairTree(directory)
    }

    static func repairTree(_ directory: URL) throws -> Int {
        try Task.checkCancellation()
        var skippedPermissionErrors = (try prepareDirectory(directory)) ? 0 : 1
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch where isPermissionDenied(error) {
                skippedPermissionErrors += 1
                continue
            }
            // Files can contain a user-created link. Do not follow it or prevent other records opening.
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                skippedPermissionErrors += try repairTree(child)
            } else {
                do {
                    if !(try apply(to: child)) { skippedPermissionErrors += 1 }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    continue
                }
            }
        }
        return skippedPermissionErrors
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
        // Atomic replacement can discard resource values, so set them on the resulting file.
        _ = try apply(to: url)
    }
}
