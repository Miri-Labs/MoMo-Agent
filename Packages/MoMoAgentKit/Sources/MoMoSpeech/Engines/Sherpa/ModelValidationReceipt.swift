import Darwin
import Foundation
import MoMoContracts

/// App-owned immutable cache: reuse a full validation only while every file's identity is unchanged.
struct ModelValidationReceipt: Codable, Equatable {
    private static let filename = ".validated-model-v1.json"
    private let manifestHash: String
    private let files: [String: Stamp]

    private struct Stamp: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    static func snapshot(at directory: URL, manifestHash: String,
                         sizes: [String: Int64], attempt: SpeechAttempt) throws -> Self {
        var files: [String: Stamp] = [:]
        for (name, byteCount) in sizes {
            try attempt.checkCancellation()
            let url = directory.appendingPathComponent(name)
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &info) } ?? -1
            }
            guard result == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == byteCount else {
                throw SpeechError.modelHashMismatch(name)
            }
            // ctime also detects same-size writes whose mtime was restored.
            files[name] = Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
        return Self(manifestHash: manifestHash, files: files)
    }

    static func read(at directory: URL) -> Self? {
        let url = directory.appendingPathComponent(filename)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size <= 65_536,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? WireJSON.decode(Self.self, from: data)
    }

    func save(at directory: URL) throws {
        try WireJSON.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
