import Darwin
import Foundation
import MoMoContracts

/// Bridges the crash window between closing an encoder file and indexing it in RecordingStore.
enum SealedCaptureSpool {
    static func sidecar(for audio: URL) -> URL { audio.appendingPathExtension("sealed.json") }
    static func draftURL(for audio: URL) -> URL { audio.appendingPathExtension("draft.json") }

    static func preserveDraft(_ draft: CaptureDraft, audio: URL) throws {
        let url = draftURL(for: audio)
        try WireJSON.encode(draft).write(to: url, options: .atomic)
        try synchronize(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func preserve(_ chunk: EncodedChunk) throws {
        try synchronize(chunk.audioURL)
        let metadata = sidecar(for: chunk.audioURL)
        try WireJSON.encode(chunk.envelope).write(to: metadata, options: .atomic)
        try synchronize(metadata)
        try synchronizeDirectory(metadata.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let result = fsync(descriptor), savedError = errno
        let closed = close(descriptor)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: savedError) ?? .EIO) }
        guard closed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func remove(_ chunk: EncodedChunk) throws {
        if FileManager.default.fileExists(atPath: chunk.audioURL.path) { try FileManager.default.removeItem(at: chunk.audioURL) }
        let draft = draftURL(for: chunk.audioURL)
        if FileManager.default.fileExists(atPath: draft.path) { try FileManager.default.removeItem(at: draft) }
        try FileManager.default.removeItem(at: sidecar(for: chunk.audioURL))
        try synchronizeDirectory(chunk.audioURL.deletingLastPathComponent())
    }

    private static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { let original = error; try handle.close(); throw original }
    }
}

public struct CaptureSpoolRecovery: Sendable {
    public var recovered: [UUID] = []
    public var incompleteFiles: [String] = []
    public var damagedFiles: [String] = []
    public init() {}
}

public enum CaptureSpool {
    /// Unknown legacy audio stays in repair; a validated draft supplies explicit deletion ownership.
    public static func removeConfirmedRepairFiles(sessionID: UUID, directory: URL) throws {
        let repair = directory.appendingPathComponent("Repair").appendingPathComponent(sessionID.uuidString)
        guard try entryKind(directory) == .directory,
              try entryKind(directory.appendingPathComponent("Repair")) == .directory,
              try entryKind(repair) == .directory else { return }
        for epoch in try children(repair) {
            guard try entryKind(epoch) == .directory, UUID(uuidString: epoch.lastPathComponent) != nil else { continue }
            for draftURL in try children(epoch).filter({ $0.lastPathComponent.hasSuffix(".m4a.draft.json") }) {
                guard try entryKind(draftURL) == .regular else { continue }
                let draft: CaptureDraft
                do { draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: draftURL)) }
                catch is DecodingError { continue }
                let audio = draftURL.deletingPathExtension().deletingPathExtension()
                guard draft.version == 1, draft.sessionID == sessionID,
                      draft.epochID.uuidString == epoch.lastPathComponent,
                      audio.lastPathComponent == draft.chunkID.uuidString + ".m4a" else { continue }
                let audioKind = try entryKind(audio)
                guard audioKind == nil || audioKind == .regular else { continue }
                if audioKind != nil { try FileManager.default.removeItem(at: audio) }
                try FileManager.default.removeItem(at: draftURL)
            }
            try SealedCaptureSpool.synchronizeDirectory(epoch)
            if try children(epoch).isEmpty { try FileManager.default.removeItem(at: epoch) }
        }
        try SealedCaptureSpool.synchronizeDirectory(repair)
        if try children(repair).isEmpty { try FileManager.default.removeItem(at: repair) }
        try SealedCaptureSpool.synchronizeDirectory(repair.deletingLastPathComponent())
    }

    public static func recover(directory: URL, store: RecordingStore, excludingOpenEpochs: Bool = false) async throws -> CaptureSpoolRecovery {
        let files = FileManager.default
        var report = CaptureSpoolRecovery()
        guard let rootKind = try entryKind(directory) else { return report }
        guard rootKind == .directory else { report.damagedFiles.append(directory.lastPathComponent); return report }
        for session in try children(directory) {
            await Task.yield()
            try Task.checkCancellation()
            if session.lastPathComponent == "Repair" {
                if try entryKind(session) != .directory { report.damagedFiles.append("Repair") }
                else if try !children(session).isEmpty { report.incompleteFiles.append("Repair") }
                continue
            }
            guard UUID(uuidString: session.lastPathComponent) != nil, try entryKind(session) == .directory else {
                try quarantineUnowned(session, root: directory)
                report.damagedFiles.append(session.lastPathComponent)
                continue
            }
            for epoch in try children(session) {
                await Task.yield()
                try Task.checkCancellation()
                guard let epochID = UUID(uuidString: epoch.lastPathComponent), try entryKind(epoch) == .directory else {
                    try quarantineUnowned(epoch, root: directory)
                    report.damagedFiles.append(session.lastPathComponent + "/" + epoch.lastPathComponent)
                    continue
                }
                // Foreground capture may already be writing while historical repair continues.
                if excludingOpenEpochs, try await store.isCaptureEpochOpen(epochID) { continue }
                for entry in try children(epoch) {
                    let knownSuffix = entry.pathExtension == "m4a" || entry.lastPathComponent.hasSuffix(".m4a.draft.json") || entry.lastPathComponent.hasSuffix(".m4a.sealed.json")
                    if try entryKind(entry) != .regular || !knownSuffix {
                        try quarantineUnowned(entry, root: directory)
                        report.damagedFiles.append(epoch.lastPathComponent + "/" + entry.lastPathComponent)
                    }
                }
                for draftURL in try children(epoch).filter({ $0.lastPathComponent.hasSuffix(".m4a.draft.json") }) {
                    await Task.yield()
                    try Task.checkCancellation()
                    guard try entryKind(draftURL) == .regular else { continue }
                    let audio = draftURL.deletingPathExtension().deletingPathExtension()
                    guard try entryKind(audio) == nil || entryKind(audio) == .regular else { continue }
                    guard try entryKind(SealedCaptureSpool.sidecar(for: audio)) == nil else { continue }
                    do {
                        let draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: draftURL))
                        guard draft.sessionID.uuidString == session.lastPathComponent,
                              draft.epochID.uuidString == epoch.lastPathComponent,
                              audio.lastPathComponent == draft.chunkID.uuidString + ".m4a" else {
                            throw RecordingError.contentConflict(draft.chunkID)
                        }
                        let envelope: ManifestEnvelope
                        if let indexed = try await store.chunk(id: draft.chunkID) {
                            guard indexed.state != .missing, indexed.state != .damaged else { throw RecordingError.invalidAudio(draft.chunkID) }
                            if !files.fileExists(atPath: audio.path) {
                                if indexed.state == .ready {
                                    guard try ContentHash.sha256(fileAt: indexed.audioURL) == indexed.envelope.manifest.audioSHA256 else {
                                        throw RecordingError.invalidAudio(draft.chunkID)
                                    }
                                }
                                try files.removeItem(at: draftURL)
                                try SealedCaptureSpool.synchronizeDirectory(epoch)
                                continue
                            }
                            envelope = indexed.envelope
                        } else {
                            envelope = try draft.envelope(audioURL: audio)
                        }
                        let chunk = EncodedChunk(audioURL: audio, envelope: envelope)
                        try SealedCaptureSpool.preserve(chunk)
                    } catch {
                        guard isUnrecoverableDraft(error) else { throw error }
                        try quarantine([audio, draftURL], from: epoch, root: directory)
                        report.incompleteFiles.append(audio.lastPathComponent)
                    }
                }
                let entries = try children(epoch)
                for sidecar in entries.filter({ $0.lastPathComponent.hasSuffix(".m4a.sealed.json") }) {
                    await Task.yield()
                    try Task.checkCancellation()
                    guard try entryKind(sidecar) == .regular else { continue }
                    do {
                        let envelope = try WireJSON.decode(ManifestEnvelope.self, from: Data(contentsOf: sidecar))
                        let manifest = envelope.manifest
                        guard manifest.sessionID.uuidString == session.lastPathComponent,
                              manifest.epochID.uuidString == epoch.lastPathComponent,
                              sidecar.lastPathComponent == manifest.chunkID.uuidString + ".m4a.sealed.json" else {
                            throw RecordingError.contentConflict(manifest.chunkID)
                        }
                        let audio = epoch.appendingPathComponent(manifest.chunkID.uuidString).appendingPathExtension("m4a")
                        guard try entryKind(audio) == nil || entryKind(audio) == .regular else { continue }
                        let chunk = EncodedChunk(audioURL: audio, envelope: envelope)
                        // A crash after the ledger commit and audio removal may leave just this sidecar.
                        if let indexed = try await store.chunk(id: manifest.chunkID) {
                            guard indexed.envelope.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(manifest.chunkID) }
                            if indexed.state == .missing || indexed.state == .damaged { throw RecordingError.invalidAudio(manifest.chunkID) }
                            if indexed.state == .ready {
                                guard try ContentHash.sha256(fileAt: indexed.audioURL) == manifest.audioSHA256 else { throw RecordingError.invalidAudio(manifest.chunkID) }
                            }
                        } else {
                            do { _ = try await store.sealChunk(audioAt: audio, envelope: envelope) }
                            catch RecordingError.deletedSession { try SealedCaptureSpool.remove(chunk); continue }
                        }
                        try SealedCaptureSpool.remove(chunk)
                        report.recovered.append(manifest.chunkID)
                    } catch is DecodingError {
                        report.damagedFiles.append(sidecar.lastPathComponent)
                    } catch is ContractError {
                        report.damagedFiles.append(sidecar.lastPathComponent)
                    } catch let error as RecordingError {
                        switch error {
                        case .invalidAudio, .contentConflict: report.damagedFiles.append(sidecar.lastPathComponent)
                        default: throw error
                        }
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        report.incompleteFiles.append(sidecar.lastPathComponent)
                    }
                }
                for audio in entries where audio.pathExtension == "m4a" {
                    guard try entryKind(audio) == .regular else { continue }
                    // Pre-draft versions cannot recover frame identity from audio alone.
                    if try entryKind(SealedCaptureSpool.sidecar(for: audio)) == nil {
                        try quarantine([audio], from: epoch, root: directory)
                    }
                    report.incompleteFiles.append(audio.lastPathComponent)
                }
            }
        }
        return report
    }

    private static func isUnrecoverableDraft(_ error: any Error) -> Bool {
        if error is DecodingError || error is ContractError { return true }
        if let writer = error as? AACWriterError {
            switch writer {
            case .invalidFormat, .conversionFailed, .decodedFrameMismatch: return true
            case .allocationFailed, .inputTooLarge: return false
            }
        }
        if let recording = error as? RecordingError {
            switch recording {
            case .contentConflict, .invalidAudio: return true
            default: break
            }
        }
        if let cocoa = error as? CocoaError,
           [.fileReadNoSuchFile, .fileNoSuchFile, .fileReadCorruptFile].contains(cocoa.code) { return true }
        return CaptureAudioReadFailure.requiresRepair(error)
    }

    private static func quarantine(_ urls: [URL], from epoch: URL, root: URL) throws {
        let base = root.appendingPathComponent("Repair")
        let session = base.appendingPathComponent(epoch.deletingLastPathComponent().lastPathComponent)
        let repair = session.appendingPathComponent(epoch.lastPathComponent)
        // A damaged repair destination must not redirect writes or block healthy source files.
        guard try ensureDirectory(base), try ensureDirectory(session), try ensureDirectory(repair) else { return }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: repair.appendingPathComponent(url.lastPathComponent))
        }
        try SealedCaptureSpool.synchronizeDirectory(repair)
        try SealedCaptureSpool.synchronizeDirectory(repair.deletingLastPathComponent())
        try SealedCaptureSpool.synchronizeDirectory(root.appendingPathComponent("Repair"))
        try SealedCaptureSpool.synchronizeDirectory(root)
        try SealedCaptureSpool.synchronizeDirectory(epoch)
    }

    private static func children(_ directory: URL) throws -> [URL] {
        guard try entryKind(directory) == .directory else { throw RecordingError.invalidDirectory(directory.lastPathComponent) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private enum EntryKind: Equatable { case directory, regular, other }

    private static func entryKind(_ url: URL) throws -> EntryKind? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFREG): return .regular
        default: return .other
        }
    }

    private static func ensureDirectory(_ url: URL) throws -> Bool {
        if let kind = try entryKind(url) { return kind == .directory }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try SealedCaptureSpool.synchronizeDirectory(url.deletingLastPathComponent())
        return true
    }

    private static func quarantineUnowned(_ entry: URL, root: URL) throws {
        let base = root.appendingPathComponent("Repair")
        let unowned = base.appendingPathComponent("Unowned")
        let destination = unowned.appendingPathComponent(UUID().uuidString)
        guard try ensureDirectory(base), try ensureDirectory(unowned), try ensureDirectory(destination) else { return }
        // rename moves the directory entry itself; it never reads a symbolic link's target.
        try FileManager.default.moveItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        try SealedCaptureSpool.synchronizeDirectory(destination)
        try SealedCaptureSpool.synchronizeDirectory(entry.deletingLastPathComponent())
    }
}
