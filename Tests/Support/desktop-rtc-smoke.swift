import Foundation
import CoreVideo
import AppKit
import TailscaleKit
@preconcurrency import WebRTC

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

private final class PixelChanges: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<UInt8>()
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let y = frame.buffer.toI420().dataY[0]
        lock.withLock { _ = values.insert(y) }
    }
    var count: Int { lock.withLock { values.count } }
}

// Real native peers + two embedded Tailscale nodes + local test control/DERP.
// Synthetic moving pixels only: this test never captures the user's screen.
@main struct DesktopRTCSmoke {
    @MainActor static func main() async throws {
        for (width, height) in [(1080,1920), (1920,1080), (4000,4000), (7680,2160), (1,1)] {
            let size = DesktopVideoCapture.dimensions(width: width, height: height)
            precondition(max(size.0,size.1) <= 1280 && ((size.0+15)/16)*((size.1+15)/16) <= 3600)
        }
        let control = CommandLine.arguments[1]
        let realCapture = CommandLine.arguments.contains("--capture")
        if realCapture && !CGPreflightScreenCaptureAccess() {
            FileHandle.standardError.write(Data("UNVERIFIED real capture: probe has no Screen Recording permission\n".utf8)); exit(77)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("momo-rtc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TailscaleNode(config: Configuration(hostName: "rtc-viewer", path: root.appendingPathComponent("viewer").path, authKey: "test", controlURL: control), logger: nil)
        let second = try TailscaleNode(config: Configuration(hostName: "rtc-host", path: root.appendingPathComponent("host").path, authKey: "test", controlURL: control), logger: nil)
        try await first.up(); try await second.up()
        FileHandle.standardError.write(Data("nodes up; encoders=\(RTCDefaultVideoEncoderFactory.supportedCodecs().map { $0.name })\n".utf8))
        let viewer = try DesktopRTC(sending: false), host = try DesktopRTC(sending: true)
        FileHandle.standardError.write(Data("peers created\n".utf8))
        let changes = PixelChanges()
        viewer.onTrack = { $0.add(changes) }
        host.handleControl = { request in (200, request.body) }
        let a = try await first.openMediaRoute(), b = try await second.openMediaRoute()
        FileHandle.standardError.write(Data("routes created\n".utf8))
        let offer = try await viewer.localDescription()
        try await host.remoteDescription(DesktopSDP.route(offer, through: b.local), answer: false)
        let answer = try await host.localDescription(answer: true)
        try await first.configureMediaRoute(a, source: DesktopSDP.endpoint(offer), remote: b.tailnet)
        try await second.configureMediaRoute(b, source: DesktopSDP.endpoint(answer), remote: a.tailnet)
        try await viewer.remoteDescription(DesktopSDP.route(answer, through: a.local), answer: true)
        let capture = DesktopVideoCapture()
        if realCapture, let source = host.source, let capturer = host.capturer { try await capture.start(source: source, capturer: capturer, failed: { host.close() }) }
        let video = Task { @MainActor in
            guard !realCapture else { return }
            for index in 0..<240 {
                if Task.isCancelled { return }
                var buffer: CVPixelBuffer?
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else { fatalError("pixel allocation") }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(index % 255), CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
                if let source = host.source, let capturer = host.capturer { source.capturer(capturer, didCapture: frame) }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        do {
            FileHandle.standardError.write(Data("negotiated\n".utf8))
            try await viewer.waitForControl()
            FileHandle.standardError.write(Data("control ready\n".utf8))
            let payload = Data("synthetic-control-receipt".utf8)
            guard try await viewer.request("status", body: payload) == payload else { throw DesktopRTCError.invalidSignal }
            try await Task.sleep(for: .seconds(5))
            let count = viewer.frames.snapshot().count
            let stats = await viewer.statistics()
            FileHandle.standardError.write(Data("capture=\(capture.statistics), frames=\(count), viewer=\(stats), host=\(await host.statistics())\n".utf8))
            guard count > (realCapture ? 5 : 30), (realCapture || changes.count > 20), stats["codec.mimeType"] == "video/H264" else { throw DesktopRTCError.unavailable }
            print(String(data: try JSONSerialization.data(withJSONObject: ["frames":count,"distinctDecodedLuma":changes.count,"statistics":stats,"control":"round-trip passed","transport":"native WebRTC through two embedded tailnet UDP bridges"], options:.sortedKeys), encoding:.utf8)!)
            video.cancel(); await capture.stop()
            let pending = Task { try await viewer.request("status", body: Data("pending".utf8)) }
            viewer.close()
            do { _ = try await pending.value; throw DesktopRTCError.invalidSignal } catch DesktopRTCError.closed {} catch DesktopRTCError.unavailable {}
            guard !viewer.controlReady else { throw DesktopRTCError.invalidSignal }
            host.close()
            try await first.close(); try await second.close()
        } catch {
            print("FAILED",error, "frames",viewer.frames.snapshot().count,"host",await host.statistics(),"viewer",await viewer.statistics())
            video.cancel();await capture.stop();viewer.close();host.close();try? await first.close();try? await second.close();throw error
        }
    }
}
