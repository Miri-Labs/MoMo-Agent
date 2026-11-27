import Foundation

public struct SpeechBundleStatus: Codable, Sendable {
    public let modelsRoot: String
    public let sileroAvailable: Bool
    public let mossAvailable: Bool
    public let redimnetAvailable: Bool
    public let sileroLoaded: Bool
    public let mossLoaded: Bool
    public let redimnetLoaded: Bool
    public let mossAcceleratorMask: Int32
    public let redimnetAcceleratorMask: Int32
    public let idleEvictionSeconds: Double
    public let lastUsedUnix: Double?
    public let thermalState: String
}

/// Manages lazy loading, serial CoreML execution, and automatic idle eviction of
/// `SileroVAD.mlmodelc`, `MOSSCoreML` (`MOSSAudioEncoder` + `MOSSDecoder` + `embedding.int8.bin`),
/// and `ReDimNet2Plus` (`ReDimNet2Plus.mlmodelc`).
public final class CoreMLBundleManager: @unchecked Sendable {
    public let modelsRoot: URL
    public let idleEvictionSeconds: TimeInterval

    private let lock = NSLock()
    private var vad: SileroVADRunner?
    private var moss: MOSSTranscriber?
    private var redimnet: ReDimNetVoiceEncoder?
    private var lastUsedDate: Date?
    private var idleTimer: DispatchSourceTimer?

    public static var defaultModelsRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("MoMoAgent", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("speech-coreml-v1", isDirectory: true)
    }

    public init(modelsRoot: URL = CoreMLBundleManager.defaultModelsRoot, idleEvictionSeconds: TimeInterval = 1800) {
        self.modelsRoot = modelsRoot
        self.idleEvictionSeconds = idleEvictionSeconds
        startIdleWatchdog()
    }

    deinit {
        idleTimer?.cancel()
    }

    public var sileroDir: URL { modelsRoot.appendingPathComponent("SileroVAD", isDirectory: true) }
    public var mossDir: URL { modelsRoot.appendingPathComponent("MOSSCoreML", isDirectory: true) }
    public var redimnetDir: URL { modelsRoot.appendingPathComponent("ReDimNet2Plus", isDirectory: true) }

    public var sileroAvailable: Bool {
        FileManager.default.fileExists(atPath: sileroDir.appendingPathComponent("SileroVAD.mlmodelc").path)
    }

    public var mossAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: mossDir.appendingPathComponent("MOSSAudioEncoder.mlmodelc").path)
            && fm.fileExists(atPath: mossDir.appendingPathComponent("MOSSDecoder.mlmodelc").path)
            && fm.fileExists(atPath: mossDir.appendingPathComponent("embedding.int8.bin").path)
            && fm.fileExists(atPath: mossDir.appendingPathComponent("moss_coreml_config.json").path)
    }

    public var redimnetAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: redimnetDir.appendingPathComponent("ReDimNet2Plus.mlmodelc").path)
            && fm.fileExists(atPath: redimnetDir.appendingPathComponent("redimnet2_config.json").path)
    }

    public func status() -> SpeechBundleStatus {
        lock.lock()
        defer { lock.unlock() }
        return SpeechBundleStatus(
            modelsRoot: modelsRoot.path,
            sileroAvailable: sileroAvailable,
            mossAvailable: mossAvailable,
            redimnetAvailable: redimnetAvailable,
            sileroLoaded: vad?.usesCoreML ?? false,
            mossLoaded: moss != nil,
            redimnetLoaded: redimnet != nil,
            mossAcceleratorMask: moss?.acceleratorMask ?? 0,
            redimnetAcceleratorMask: redimnet?.acceleratorMask ?? 0,
            idleEvictionSeconds: idleEvictionSeconds,
            lastUsedUnix: lastUsedDate?.timeIntervalSince1970,
            thermalState: Self.thermalStateString()
        )
    }

    public func getVAD() -> SileroVADRunner {
        lock.lock()
        defer { lock.unlock() }
        lastUsedDate = Date()
        if let existing = vad { return existing }
        let url = sileroAvailable ? sileroDir.appendingPathComponent("SileroVAD.mlmodelc") : nil
        let runner = SileroVADRunner(modelURL: url)
        vad = runner
        return runner
    }

    public func getMOSS() throws -> MOSSTranscriber {
        lock.lock()
        defer { lock.unlock() }
        lastUsedDate = Date()
        if let existing = moss { return existing }
        guard mossAvailable else {
            throw SpeechEngineError.invalidBundle("MOSSCoreML bundle missing in \(mossDir.path)")
        }
        let engine = try MOSSTranscriber(bundleDirectory: mossDir)
        moss = engine
        return engine
    }

    public func getReDimNet() throws -> ReDimNetVoiceEncoder {
        lock.lock()
        defer { lock.unlock() }
        lastUsedDate = Date()
        if let existing = redimnet { return existing }
        guard redimnetAvailable else {
            throw SpeechEngineError.invalidBundle("ReDimNet2Plus bundle missing in \(redimnetDir.path)")
        }
        let encoder = try ReDimNetVoiceEncoder(bundleDirectory: redimnetDir)
        redimnet = encoder
        return encoder
    }

    /// Pre-loads CoreML bundles quietly on a utility background queue so first-time e5rt specialization
    /// finishes before the user's first recording or dictation arrives.
    public func warmUpInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let thermal = ProcessInfo.processInfo.thermalState
            guard thermal == .nominal || thermal == .fair else { return }
            _ = self.getVAD()
            if self.redimnetAvailable {
                _ = try? self.getReDimNet()
            }
            if self.mossAvailable {
                _ = try? self.getMOSS()
            }
        }
    }

    /// Unloads heavy CoreML handles (MOSS + ReDimNet2+) to release unified memory.
    public func unloadHeavyModels() {
        lock.lock()
        moss = nil
        redimnet = nil
        lock.unlock()
    }

    public func unloadAll() {
        lock.lock()
        vad = nil
        moss = nil
        redimnet = nil
        lock.unlock()
    }

    private func startIdleWatchdog() {
        guard idleEvictionSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldEvict: Bool
            if let last = self.lastUsedDate, (self.moss != nil || self.redimnet != nil) {
                shouldEvict = Date().timeIntervalSince(last) >= self.idleEvictionSeconds
            } else {
                shouldEvict = false
            }
            if shouldEvict {
                self.moss = nil
                self.redimnet = nil
            }
            self.lock.unlock()
        }
        timer.resume()
        self.idleTimer = timer
    }

    private static func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
