import Foundation
import MoMoContracts

/// WCSession owns the directory and changes it with the selected Watch; no inbox identity chooses this path.
enum SelectedWatchStatusFile {
    static func read(directory: URL, libraryID: UUID) throws -> StatusSnapshot? {
        let file = try location(directory: directory, libraryID: libraryID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= StatusSnapshot.maximumEncodedBytes else { throw Failure.invalidFile }
        return try WireJSON.decode(StatusSnapshot.self, from: Data(contentsOf: file))
    }

    static func write(_ snapshot: StatusSnapshot, directory: URL, libraryID: UUID) throws {
        let file = try location(directory: directory, libraryID: libraryID)
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidFile }
        }
        try WireJSON.encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    private static func location(directory: URL, libraryID: UUID) throws -> URL {
        guard directory.isFileURL else { throw Failure.invalidDirectory }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidDirectory }
        return directory.appendingPathComponent("momoagent-status-\(libraryID.uuidString).json")
    }

    private enum Failure: Error { case invalidDirectory, invalidFile }
}
