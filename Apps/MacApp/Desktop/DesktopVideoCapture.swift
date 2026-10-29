import AppKit
import ScreenCaptureKit
@preconcurrency import WebRTC

/// Pixel buffers go directly from ScreenCaptureKit to WebRTC/VideoToolbox.
/// No JPEG, base64 or CPU image conversion in the interactive video path.
@MainActor final class DesktopVideoCapture {
    private var stream: SCStream?
    private var output: DesktopVideoOutput?
    private var keepAlive: Task<Void, Never>?
    private var generation = UUID()
    // Default Apple libwebrtc advertises H.264 level 3.1: at most 3600
    // macroblocks/frame at 30 fps. Enforce area too (square displays included).
    nonisolated static func dimensions(width: Int, height: Int) -> (Int, Int) {
        let width = max(2, width), height = max(2, height)
        var scale = min(1, 1280 / Double(max(width, height)), sqrt(921600 / (Double(width) * Double(height))))
        func sized() -> (Int, Int) { (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2)) }
        var size = sized()
        while ((size.0 + 15) / 16) * ((size.1 + 15) / 16) > 3600 { scale *= 0.99; size = sized() }
        return size
    }
    func start(source: RTCVideoSource, capturer: RTCVideoCapturer, failed: @escaping @MainActor () -> Void) async throws {
        let attempt = generation
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw DesktopError.message("电脑显示器暂时不可用。") }
        let configuration = SCStreamConfiguration()
        let (width, height) = Self.dimensions(width: display.width, height: display.height)
        configuration.width = max(2, width / 2 * 2); configuration.height = max(2, height / 2 * 2)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3; configuration.showsCursor = true
        configuration.capturesAudio = false
        let output = DesktopVideoOutput(source: source, capturer: capturer)
        self.output = output
        let next = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: output)
        try next.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "momo.desktop.video", qos: .userInteractive))
        try await next.startCapture()
        guard attempt == generation, !Task.isCancelled else { try? await next.stopCapture(); output.stop(); throw CancellationError() }
        stream = next
        let displayID = display.displayID
        let pixels = CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        keepAlive = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                // SCK omits unchanged frames. Feed the latest buffer to preserve
                // fresh RTP/keyframes; never replay an unavailable/locked display.
                guard output.repeatIdle(), displayID == CGMainDisplayID(), pixels == CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)) else { failed(); return }
            }
        }
    }
    var statistics: [String: String] { output?.statistics ?? [:] }
    func stop() async {
        generation = UUID(); keepAlive?.cancel(); keepAlive = nil
        output?.stop(); output = nil
        let previous = stream; stream = nil
        try? await previous?.stopCapture()
    }
}

private final class DesktopVideoOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private var latest: CVPixelBuffer?
    private var stopped = false
    private var failed = false
    private var lastSent: UInt64 = 0
    private var received = 0
    private var complete = 0
    private var statuses: [Int: Int] = [:]
    var statistics: [String: String] { lock.withLock { ["samples": String(received), "complete": String(complete), "statuses": String(describing: statuses), "failed": String(failed)] } }
    init(source: RTCVideoSource, capturer: RTCVideoCapturer) { self.source = source; self.capturer = capturer }
    func stop() { lock.withLock { stopped = true; latest = nil } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.withLock { failed = true; latest = nil } }
    func repeatIdle() -> Bool {
        lock.withLock {
            guard !stopped, !failed else { return false }
            if let latest, DispatchTime.now().uptimeNanoseconds - lastSent > 400_000_000 { emit(latest) }
            return true
        }
    }
    private func emit(_ pixels: CVPixelBuffer) {
        lastSent = DispatchTime.now().uptimeNanoseconds
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: Int64(lastSent)))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        lock.withLock {
            guard !stopped else { return }
            received += 1; statuses[raw, default: 0] += 1
            if status == .idle { return }
            guard status == .complete, let pixels = sampleBuffer.imageBuffer else { latest = nil; return }
            complete += 1; latest = pixels; emit(pixels)
        }
    }
}
