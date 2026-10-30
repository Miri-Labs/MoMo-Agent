import AppKit
import Foundation

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

/// Launch only with disposable data. The driver verifies ownership rejections, never posts input.
@main struct DesktopControlProbe {
    @MainActor static func main() throws {
        for (width, height) in [(1080, 1920), (7680, 2160), (1, 1), (0, 0)] {
            let size = DesktopScreenStream.size(width: width, height: height)
            precondition(size.0 > 0 && size.1 > 0 && max(size.0, size.1) <= 1440)
        }
        FileHandle.standardError.write(Data("desktop probe entered\n".utf8))
        let data = URL(fileURLWithPath: CommandLine.arguments[1])
        let host = try DesktopControlHost(data: data, key: "synthetic-private-ipc-key", tailnet: EmbeddedTailnet(directory: data.appendingPathComponent("tailnet"), device: "fixture"), controlPort: 18768)
        FileHandle.standardError.write(Data("desktop host started\n".utf8))
        defer { host.stop() }
        dispatchMain()
    }
}
