import AppKit
import ScreenCaptureKit
import VideoToolbox

/// One live capture source, one newest image. Idle previews release capture resources.
@MainActor final class DesktopScreenStream {
    private var stream: SCStream?
    private var starting: Task<Void, Error>?
    private var output = DesktopScreenOutput()
    private var displayID: CGDirectDisplayID?
    private var displayPixels: CGSize?
    private var generation = UUID()
    private var idle: Task<Void, Never>?

    nonisolated static func size(width: Int, height: Int, edge: Int = 1440) -> (Int, Int) {
        let scale = min(1, Double(edge) / Double(max(1, max(width, height))))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    func frame() async throws -> CGImage {
        let mainDisplay = CGMainDisplayID()
        let pixels = CGSize(width: CGDisplayPixelsWide(mainDisplay), height: CGDisplayPixelsHigh(mainDisplay))
        if displayID != nil && (displayID != mainDisplay || displayPixels != pixels) { await stop() }
        idle?.cancel()
        defer {
            idle = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                await self?.stop()
            }
        }
        if stream == nil {
            let generation = self.generation
            if starting == nil {
                starting = Task {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                        throw DesktopError.message("电脑显示器暂时不可用。")
                    }
                    let configuration = SCStreamConfiguration()
                    let (width, height) = Self.size(width: display.width, height: display.height)
                    configuration.width = width; configuration.height = height
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                    configuration.queueDepth = 3; configuration.showsCursor = true
                    // A retired stream must never overwrite the new source's frame.
                    let output = DesktopScreenOutput()
                    self.output = output
                    let next = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: output)
                    try next.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "momo.desktop.capture", qos: .userInitiated))
                    try await next.startCapture()
                    guard !Task.isCancelled, generation == self.generation else {
                        try? await next.stopCapture(); throw CancellationError()
                    }
                    stream = next
                    displayID = display.displayID
                    displayPixels = pixels
                }
            }
            do { try await starting?.value; if generation == self.generation { starting = nil } }
            catch { if generation == self.generation { starting = nil }; throw error }
        }
        for _ in 0..<80 {
            try Task.checkCancellation()
            let state = output.snapshot()
            if state.failed { await stop(); throw DesktopError.message("屏幕采集已暂停，请重试。") }
            if let image = state.image { return image }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DesktopError.message("尚未收到电脑画面，请确认显示器已唤醒。")
    }

    func stop() async {
        idle?.cancel(); idle = nil
        generation = UUID()
        let previous = stream, previousOutput = output
        stream = nil; displayID = nil; displayPixels = nil
        let pending = starting; starting = nil
        pending?.cancel()
        _ = try? await pending?.value
        try? await previous?.stopCapture()
        previousOutput.clear()
    }
}

private final class DesktopScreenOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var failed = false
    func clear() { lock.withLock { image = nil; failed = false } }
    func snapshot() -> (image: CGImage?, failed: Bool) { lock.withLock { (image, failed) } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.withLock { image = nil; failed = true } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle { return } // Unchanged desktop: the last complete image is still current.
        guard status == .complete, let pixels = sampleBuffer.imageBuffer else {
            lock.withLock { image = nil }; return
        }
        var next: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &next) == noErr, let next else { return }
        lock.withLock { image = next; failed = false }
    }
}
