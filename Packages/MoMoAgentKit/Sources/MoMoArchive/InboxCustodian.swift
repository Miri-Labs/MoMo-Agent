import Foundation
import MoMoContracts

/// Synchronous ownership handoff for temporary WatchConnectivity files.
public struct InboxCustodian: Sendable {
    public let rootURL: URL
    // A new custodian must not recover a handoff another callback is still writing.
    private static let handoffLock = NSLock()
    #if DEBUG && os(macOS)
    private var receiveObserver: (@Sendable (ArchiveReceiveBoundary) -> Void)?

    public init(rootURL: URL, receiveObserver: @escaping @Sendable (ArchiveReceiveBoundary) -> Void) throws {
        try self.init(rootURL: rootURL)
        self.receiveObserver = receiveObserver
    }
    #endif
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try ArchiveFilePolicy.prepareDirectory(rootURL)
        try Self.handoffLock.withLock { try recoverInterruptedHandoffs() }
    }

    public func preserve(fileURL: URL, manifestData: Data, manifestSHA256: String) throws -> InboxItem {
        let envelope = try ManifestEnvelope(manifestData: manifestData, manifestSHA256: manifestSHA256)
        return try preserve(fileURL: fileURL, envelope: envelope)
    }

    public func preserve(fileURL: URL, envelope: ManifestEnvelope) throws -> InboxItem {
        try Self.handoffLock.withLock { try preserveLocked(fileURL: fileURL, envelope: envelope) }
    }

    private func preserveLocked(fileURL: URL, envelope: ManifestEnvelope) throws -> InboxItem {
        guard envelope.manifestData.count <= 16_384 else { throw ArchiveError.invalidInbox }
        let id = UUID()
        let ready = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let directory = ready.appendingPathExtension("receiving")
        try ArchiveFilePolicy.prepareDirectory(directory)
        // Only the final same-directory rename publishes this handoff to readers.
        try ArchiveFilePolicy.write(envelope.manifestData, to: directory.appendingPathComponent("manifest.json"))
        try ArchiveFilePolicy.write(Data(envelope.manifestSHA256.utf8), to: directory.appendingPathComponent("manifest.sha256"))
        for name in ["manifest.json", "manifest.sha256"] {
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
            do { try handle.synchronize(); try handle.close() }
            catch { try handle.close(); throw error }
        }
        #if DEBUG && os(macOS)
        receiveObserver?(.inboxManifestSynced)
        #endif
        let audioURL = directory.appendingPathComponent("audio")
        try FileManager.default.moveItem(at: fileURL, to: audioURL)
        try ArchiveFilePolicy.apply(to: audioURL)
        let handle = try FileHandle(forWritingTo: audioURL)
        do { try handle.synchronize(); try handle.close() }
        catch { try handle.close(); throw error }
        try FileManager.default.moveItem(at: directory, to: ready)
        return InboxItem(id: id, directoryURL: ready)
    }

    public func pendingItems() throws -> [InboxItem] {
        try storedItems(includingIncomplete: false)
    }

    func storedItems(includingIncomplete: Bool) throws -> [InboxItem] {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let name = includingIncomplete && url.pathExtension == "incomplete"
                    ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                guard let id = UUID(uuidString: name) else { return nil }
                return InboxItem(id: id, directoryURL: url)
            }
    }

    private func recoverInterruptedHandoffs() throws {
        let files = FileManager.default
        for directory in try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            let receiving = directory.pathExtension == "receiving"
            let ready = receiving ? directory.deletingPathExtension() : directory
            guard UUID(uuidString: ready.lastPathComponent) != nil else { continue }
            // Missing inbox audio is valid for a published entry: commit may have moved it already.
            let required = receiving ? ["manifest.json", "manifest.sha256", "audio"] : ["manifest.json", "manifest.sha256"]
            let complete = try required.allSatisfy { name in
                do {
                    return try files.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.type] as? FileAttributeType == .typeRegular
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    return false
                }
            }
            if !complete {
                // Retain all bytes without retrying a handoff that cannot be verified. The Watch keeps its unacknowledged original.
                try files.moveItem(at: directory, to: ready.appendingPathExtension("incomplete"))
            } else if receiving {
                try files.moveItem(at: directory, to: ready)
            }
        }
    }
}
