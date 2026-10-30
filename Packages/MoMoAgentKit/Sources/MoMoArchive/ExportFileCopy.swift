import CryptoKit
import Foundation
import MoMoContracts

enum ExportFileCopy {
    static let bufferSize = 64 * 1_024

    static func stage(_ ticket: RecordingExportTicket) throws {
        try Task.checkCancellation()
        try ArchiveFilePolicy.prepareDirectory(ticket.export.directory)
        for input in ticket.inputs {
            try copy(input, to: ticket.export.directory.appendingPathComponent(input.filename))
        }
        try Task.checkCancellation()
        try ArchiveFilePolicy.write(ticket.index, to: ticket.export.directory.appendingPathComponent("recording.json"))
        let note = """
        MoMo Agent 主动导出

        导出时间：\(ticket.export.createdAt.ISO8601Format())
        这是手机当前已接收资料的快照，不代表全天声音已完整采集、接收或转写。
        原音按分片保留，没有拼接或补齐缺口。recording.json 保存各分片的时钟、帧范围和校验值。
        仅复制仍可读取且通过校验的原音。audioOmission 标明未导出的分片：expired 为已过期，expiry_pending 为正在清理，missing_unexpected 为文件缺失，not_requested 为本次未选择原音。
        epochs.notReceived 是已知范围内尚未收到的帧；unknownTailFromFrame 之后的范围仍未知，不能当作静音或完整录音。
        转录仅包含此时已完成的文字；后续转写和修改不会更新这份副本。
        你保存或分享出去的文件由目标位置管理，App 的原音保留期不会删除这些副本。
        """
        try ArchiveFilePolicy.write(Data(note.utf8), to: ticket.export.directory.appendingPathComponent("README.txt"))
    }

    /// File handles never cross an await; cancellation and hashing share a fixed-size copy buffer.
    static func copy(_ input: ExportFileInput, to destination: URL,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        let source = try FileHandle(forReadingFrom: input.source)
        defer { try? source.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try ArchiveFilePolicy.apply(to: destination)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try checkCancellation()
            guard let data = try source.read(upToCount: bufferSize), !data.isEmpty else { break }
            count += Int64(data.count)
            guard count <= input.byteCount else { throw ArchiveError.byteCountMismatch }
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        guard count == input.byteCount else { throw ArchiveError.byteCountMismatch }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == input.sha256 else { throw ArchiveError.checksumMismatch }
        try output.synchronize()
        try checkCancellation()
    }
}
