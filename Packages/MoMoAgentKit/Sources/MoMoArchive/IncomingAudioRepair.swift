import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Restore missing components only. Files directory deletion and conflicting bytes need user action.
    func restoreMissingAudio(from item: InboxItem, envelope: ManifestEnvelope, target: URL) throws -> Bool {
        let manifest = envelope.manifest
        guard let session = try database.rows("SELECT deleted,projection_blocked,document_directory,source_device FROM sessions WHERE id=?", [.text(manifest.sessionID.uuidString)]).first,
              session.integer(0) == 0, session.integer(1) == 0,
              session.string(3) == manifest.sourceDeviceID.uuidString,
              let directory = session.string(2), !audioLeases.values.contains(manifest.chunkID) else { return false }
        let recordingDirectory = rootURL.appendingPathComponent(directory)
        let audioDirectory = target.deletingLastPathComponent()
        guard audioDirectory.deletingLastPathComponent().standardizedFileURL.path == recordingDirectory.standardizedFileURL.path else { throw ArchiveError.invalidQuery }
        try validateRecordingPath(target)
        let storedManifest = target.appendingPathExtension("manifest.json")
        try validateRecordingPath(storedManifest)
        guard files.fileExists(atPath: recordingDirectory.path), files.fileExists(atPath: audioDirectory.path) else {
            try blockProjection(sessionID: manifest.sessionID)
            return false
        }
        guard try files.attributesOfItem(atPath: audioDirectory.path)[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.invalidQuery }
        let audioExists = try matchingFileExists(target, hash: manifest.audioSHA256, chunkID: manifest.chunkID)
        let manifestExists = try matchingFileExists(storedManifest, hash: envelope.manifestSHA256, chunkID: manifest.chunkID)

        let source = item.directoryURL.appendingPathComponent("audio")
        guard try files.attributesOfItem(atPath: item.directoryURL.path)[.type] as? FileAttributeType == .typeDirectory,
              try files.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else { throw ArchiveError.invalidInbox }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == manifest.byteCount else { throw ArchiveError.byteCountMismatch }
        guard try ContentHash.sha256(fileAt: source) == manifest.audioSHA256 else { throw ArchiveError.checksumMismatch }
        try validateAudio(at: source, manifest: manifest)

        // Keep the original inbox intact until the receipt transaction commits, including after a partial copy.
        if !audioExists {
            try publishRepairCopy(source: source, target: target, inbox: item.directoryURL)
        }
        if !manifestExists {
            let incomingManifest = item.directoryURL.appendingPathComponent("manifest.json")
            guard try files.attributesOfItem(atPath: incomingManifest.path)[.type] as? FileAttributeType == .typeRegular,
                  try ContentHash.sha256(fileAt: incomingManifest) == envelope.manifestSHA256 else { throw ArchiveError.invalidInbox }
            try publishRepairCopy(source: incomingManifest, target: storedManifest, inbox: item.directoryURL)
        }
        guard try validStoredAudio(target, envelope: envelope) else { throw ArchiveError.checksumMismatch }
        return true
    }

    private func matchingFileExists(_ url: URL, hash: String, chunkID: UUID) throws -> Bool {
        guard files.fileExists(atPath: url.path) else { return false }
        guard try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
              try ContentHash.sha256(fileAt: url) == hash else { throw ArchiveError.conflictingChunk(chunkID) }
        return true
    }

    private func publishRepairCopy(source: URL, target: URL, inbox: URL) throws {
        // Both locations are in one app container. A partial copy stays in the inbox, never at the final audio path.
        let staged = inbox.appendingPathComponent("repair-\(UUID().uuidString)")
        try files.copyItem(at: source, to: staged)
        try ArchiveFilePolicy.apply(to: staged)
        let handle = try FileHandle(forWritingTo: staged)
        do { try handle.synchronize(); try handle.close() }
        catch { try handle.close(); throw error }
        try files.moveItem(at: staged, to: target)
    }
}
