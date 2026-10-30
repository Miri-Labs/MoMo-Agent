import AVFoundation
import Foundation
import OSLog

/// Diagnostic only. A new process selects this path without constructing AVAudioEngine.
@MainActor
enum RecorderInputProbe {
    static func run(updateStatus: (String) -> Void) async -> [String: Any] {
        let began = Date()
        let runID = UUID().uuidString
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-probe-\(runID).wav")
        var report: [String: Any] = ["runID": runID, "startedAt": began.timeIntervalSince1970,
            "processID": ProcessInfo.processInfo.processIdentifier, "requestedDurationSeconds": 3,
            "scope": "AVAudioRecorder real microphone; temporary mono PCM WAV is deleted; statistics only",
            "initializationOrder": "permission -> record/default -> setActive(true) -> AVAudioRecorder; no engine",
            "temporaryAudioFileName": audio.lastPathComponent, "status": "in_progress", "decodedFrames": Int64(0)]
        let session = AVAudioSession.sharedInstance()
        let delegate = RecorderDelegate()
        var recorder: AVAudioRecorder?
        var activated = false
        save(report)
        do {
            updateStatus("等待麦克风授权")
            let granted = await AVAudioApplication.requestRecordPermission()
            report["permissionGranted"] = granted
            report["recordPermission"] = AVAudioApplication.shared.recordPermission.rawValue
            guard granted else { throw RecorderProbeFailure.permissionDenied }
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            activated = true
            report["sessionActivated"] = true
            report["sessionSampleRate"] = session.sampleRate
            report["inputAvailable"] = session.isInputAvailable
            report["inputChannels"] = session.inputNumberOfChannels
            report["routeInputs"] = session.currentRoute.inputs.map {
                ["type": $0.portType.rawValue, "channels": $0.channels?.count ?? 0] as [String: Any]
            }
            guard session.sampleRate > 0, session.sampleRate <= 192_000 else { throw RecorderProbeFailure.invalidSessionRate }
            let current = try AVAudioRecorder(url: audio, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: session.sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder = current
            current.delegate = delegate
            report["stage"] = "before_prepare"
            save(report)
            let prepared = current.prepareToRecord()
            report["prepareReturned"] = prepared
            guard prepared else { throw RecorderProbeFailure.prepareReturnedFalse }
            report["recorderFormat"] = ["sampleRate": current.format.sampleRate, "channels": current.format.channelCount]
            report["stage"] = "before_record"
            save(report)
            let recordingStart = Date()
            let accepted = current.record(forDuration: 3)
            report["recordReturned"] = accepted
            guard accepted else { throw RecorderProbeFailure.recordReturnedFalse }
            updateStatus("Recorder 实际录音中（3 秒）")
            report["stage"] = "recording"
            save(report)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            while delegate.snapshot().finished == nil && delegate.snapshot().error == nil && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            report["recordingWallSeconds"] = Date().timeIntervalSince(recordingStart)
            report["recorderTimeBeforeStop"] = current.currentTime
            let end = delegate.snapshot()
            if let finished = end.finished { report["delegateFinished"] = finished }
            if let error = end.error {
                report["delegateErrorDomain"] = error.domain
                report["delegateErrorCode"] = error.code
                throw RecorderProbeFailure.encodeError
            }
            guard let finished = end.finished else { throw RecorderProbeFailure.deadline }
            guard finished else { throw RecorderProbeFailure.unsuccessfulFinish }
            current.stop()
            let decoded = try inspect(audio)
            report.merge(decoded) { _, new in new }
            let duration = decoded["decodedDurationSeconds"] as? Double ?? 0
            report["status"] = duration >= 2.9 && duration <= 3.2 ? "captured_three_seconds" : "failed_incomplete_duration"
        } catch {
            report["status"] = "failed"
            report["error"] = String(describing: error)
            report["errorDomain"] = (error as NSError).domain
            report["errorCode"] = (error as NSError).code
        }
        recorder?.stop()
        recorder?.delegate = nil
        // A failed record can leave a partial file. Inspect it as failure evidence,
        // without turning a short/failed attempt into successful capture.
        if report["decodedSampleRate"] == nil, FileManager.default.fileExists(atPath: audio.path) {
            do { report.merge(try inspect(audio)) { _, new in new } }
            catch { report["decodeErrorDomain"] = (error as NSError).domain; report["decodeErrorCode"] = (error as NSError).code }
        }
        recorder = nil
        if activated {
            do { try session.setActive(false, options: .notifyOthersOnDeactivation); report["deactivated"] = true }
            catch { report["deactivationErrorDomain"] = (error as NSError).domain; report["deactivationErrorCode"] = (error as NSError).code }
        }
        do {
            if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
            report["temporaryAudioRemoved"] = !FileManager.default.fileExists(atPath: audio.path)
        } catch {
            report["temporaryAudioRemoved"] = false
            report["cleanupErrorDomain"] = (error as NSError).domain
            report["cleanupErrorCode"] = (error as NSError).code
            report["status"] = "failed_cleanup"
        }
        report["elapsedSeconds"] = Date().timeIntervalSince(began)
        report["stage"] = "finished"
        save(report)
        return report
    }

    private static func inspect(_ url: URL) throws -> [String: Any] {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= 3 * 1024 * 1024 else { throw RecorderProbeFailure.unexpectedFileSize }
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = reader.processingFormat
        guard format.sampleRate > 0, format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { throw RecorderProbeFailure.invalidDecodedFormat }
        var frames: Int64 = 0
        var squares = 0.0
        while reader.framePosition < reader.length {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, reader.length - reader.framePosition)))
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw RecorderProbeFailure.emptyDecode }
            for index in 0..<Int(buffer.frameLength) { let value = Double(samples[index]); squares += value * value }
            frames += Int64(buffer.frameLength)
        }
        return ["fileBytes": bytes, "containerFrames": reader.length, "decodedFrames": frames,
            "decodedSampleRate": format.sampleRate, "decodedChannels": format.channelCount,
            "decodedDurationSeconds": Double(frames) / format.sampleRate,
            "rms": frames > 0 ? sqrt(squares / Double(frames)) : 0]
    }

    private static func save(_ report: [String: Any]) {
        let logger = Logger(subsystem: "com.momoagent.diagnostics.captureprobe", category: "recorder")
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: documents.appendingPathComponent("recorder-probe.json"), options: .atomic)
            logger.notice("Recorder probe: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        } catch { logger.error("Recorder report write failed: \((error as NSError).code)") }
    }
}

private enum RecorderProbeFailure: Error {
    case permissionDenied, invalidSessionRate, prepareReturnedFalse, recordReturnedFalse
    case deadline, encodeError, unsuccessfulFinish, unexpectedFileSize, invalidDecodedFormat, emptyDecode
}

private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Bool?
    private var failure: (domain: String, code: Int)?
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        lock.withLock { finished = flag }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        lock.withLock { failure = ((error as NSError?)?.domain ?? "unspecified", (error as NSError?)?.code ?? 0) }
    }
    func snapshot() -> (finished: Bool?, error: (domain: String, code: Int)?) {
        lock.withLock { (finished: finished, error: failure) }
    }
}
