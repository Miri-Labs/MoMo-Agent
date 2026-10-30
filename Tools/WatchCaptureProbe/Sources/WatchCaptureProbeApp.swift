import AVFoundation
import Foundation
import OSLog
import SwiftUI

@main
struct WatchCaptureProbeApp: App {
    @StateObject private var probe = CaptureProbe()
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple 输入诊断").font(.headline)
                    Text("仅保留统计。Recorder 临时录音完成即删除。")
                    Button("Engine 3 秒") { probe.start() }
                        .disabled(probe.started)
                    Button("Recorder 3 秒") { probe.startRecorder() }
                        .disabled(probe.started)
                    Text(probe.status).font(.footnote)
                }
            }
            .task {
                if CommandLine.arguments.contains("--recorder-probe") { probe.startRecorder() }
                else if CommandLine.arguments.contains("--engine-probe") { probe.start() }
            }
        }
    }
}

@MainActor
private final class CaptureProbe: ObservableObject {
    @Published var started = false
    @Published var status = "尚未采样"
    private let logger = Logger(subsystem: "com.momoagent.diagnostics.captureprobe", category: "capture")

    func start() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    func startRecorder() {
        guard !started else { return }
        started = true
        Task {
            let report = await RecorderInputProbe.run { self.status = $0 }
            status = "\(report["status"] as? String ?? "unknown")\n\(report["decodedFrames"] as? Int64 ?? 0) 帧\nRMS \(report["rms"] as? Double ?? 0)"
            if let error = report["error"] as? String { status += "\n\(error)" }
        }
    }

    private func run() async {
        let began = Date()
        let asyncActivation = CommandLine.arguments.contains("--async-activation")
        var report: [String: Any] = ["startedAt": began.timeIntervalSince1970,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "scope": "Apple APIs only; no product dependencies; no PCM file or audio persistence",
            "activationAPI": asyncActivation ? "activate(options:completion:)" : "setActive(true)",
            "initializationOrder": "permission -> category record/default -> activation -> new engine -> inputNode exactly once"]
        let stats = CaptureStatistics()
        let session = AVAudioSession.sharedInstance()
        var engine: AVAudioEngine?
        var input: AVAudioInputNode?
        var installedTap = false
        var activated = false
        do {
            status = "等待麦克风授权"
            let granted = await AVAudioApplication.requestRecordPermission()
            report["permissionGranted"] = granted
            report["recordPermission"] = session.recordPermission.rawValue
            guard granted else { throw ProbeFailure.permissionDenied }
            try session.setCategory(.record, mode: .default)
            if asyncActivation {
                guard #available(iOS 27.0, *) else { throw ProbeFailure.asyncActivationUnavailable }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    session.activate(options: []) { active, error in
                        if let error { continuation.resume(throwing: error) }
                        else if active { continuation.resume() }
                        else { continuation.resume(throwing: ProbeFailure.activationFailed) }
                    }
                }
            } else {
                try session.setActive(true)
            }
            activated = true
            report["sessionActivated"] = true
            report["sessionSampleRate"] = session.sampleRate
            report["inputAvailable"] = session.isInputAvailable
            report["inputChannels"] = session.inputNumberOfChannels
            report["category"] = session.category.rawValue
            report["mode"] = session.mode.rawValue
            report["routeInputs"] = session.currentRoute.inputs.map {
                ["type": $0.portType.rawValue, "name": $0.portName, "channels": $0.channels?.count ?? 0] as [String: Any]
            }
            let freshEngine = AVAudioEngine()
            engine = freshEngine
            let singleInput = freshEngine.inputNode
            input = singleInput
            let hardware = singleInput.inputFormat(forBus: 0)
            let format = singleInput.outputFormat(forBus: 0)
            report["hardwareFormat"] = ["sampleRate": hardware.sampleRate, "channels": hardware.channelCount]
            report["tapFormat"] = ["sampleRate": format.sampleRate, "channels": format.channelCount]
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  format.sampleRate > 0, format.channelCount > 0 else { throw ProbeFailure.zeroInputFormat }
            singleInput.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in stats.observe(buffer) }
            installedTap = true
            freshEngine.prepare()
            try freshEngine.start()
            report["engineStarted"] = true
            status = "真实采样中（3 秒）"
            try await Task.sleep(for: .seconds(3))
            report["status"] = stats.snapshot().frames > 0 ? "captured_real_input_frames" : "failed_no_frames"
        } catch {
            report["status"] = "failed"
            report["error"] = String(describing: error)
            report["errorDomain"] = (error as NSError).domain
            report["errorCode"] = (error as NSError).code
        }
        engine?.stop()
        if installedTap { input?.removeTap(onBus: 0) }
        if activated {
            do { try session.setActive(false, options: .notifyOthersOnDeactivation); report["deactivated"] = true }
            catch { report["deactivationError"] = String(describing: error) }
        }
        let samples = stats.snapshot()
        report["frames"] = samples.frames
        report["rms"] = samples.rms
        report["tapCallbacks"] = samples.callbacks
        report["emptyTapCallbacks"] = samples.emptyCallbacks
        report["elapsedSeconds"] = Date().timeIntervalSince(began)
        status = "\(report["status"] as? String ?? "unknown")\n\(samples.frames) 帧\nRMS \(samples.rms)"
        if let error = report["error"] as? String { status += "\n\(error)" }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: documents.appendingPathComponent("capture-probe.json"), options: .atomic)
            logger.notice("Capture probe result: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        } catch {
            status += "\n报告保存失败：\(error)"
            logger.error("Capture probe report write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private enum ProbeFailure: Error { case permissionDenied, activationFailed, asyncActivationUnavailable, zeroInputFormat }

private final class CaptureStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: Int64 = 0
    private var sampleCount: Int64 = 0
    private var squares: Double = 0
    private var callbacks: Int64 = 0
    private var emptyCallbacks: Int64 = 0
    func observe(_ buffer: AVAudioPCMBuffer) {
        // Read only the callback's borrowed memory. No audio sample escapes this callback.
        var sum = 0.0
        var count: Int64 = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][index])
                    sum += value * value
                    count += 1
                }
            }
        }
        lock.withLock {
            callbacks += 1
            if buffer.frameLength == 0 { emptyCallbacks += 1 }
            frames += Int64(buffer.frameLength); sampleCount += count; squares += sum
        }
    }
    func snapshot() -> (frames: Int64, rms: Double, callbacks: Int64, emptyCallbacks: Int64) {
        lock.withLock { (frames, sampleCount > 0 ? sqrt(squares / Double(sampleCount)) : 0, callbacks, emptyCallbacks) }
    }
}
