import Foundation
import Observation
import MoMoMacSpeech

/// Hosts the native Apple Silicon CoreML speech engine (`SileroVAD`, `MOSS-Transcribe-Diarize 0.9B`,
/// `ReDimNet2+ LMFT B6`) in-process inside `MoMoAgentMac` on `127.0.0.1:<port + 4>`.
@MainActor @Observable
final class MacSpeechHost {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var status: SpeechBundleStatus?
    private(set) var lastError: String?

    @ObservationIgnored private var server: MacSpeechHTTPServer?
    @ObservationIgnored private var bundleManager: CoreMLBundleManager?

    func start(port: UInt16, apiKey: String, dataDirectory: URL) {
        if isRunning && self.port == port {
            refreshStatus()
            return
        }
        stop()
        let modelsRoot = Self.resolveModelsRoot(dataDirectory: dataDirectory)
        let manager = CoreMLBundleManager(modelsRoot: modelsRoot, idleEvictionSeconds: 1800)
        let srv = MacSpeechHTTPServer(port: port, authToken: apiKey, bundleManager: manager)
        do {
            try srv.start()
            self.bundleManager = manager
            self.server = srv
            self.port = port
            self.isRunning = true
            self.lastError = nil
            self.status = manager.status()
            manager.warmUpInBackground()
        } catch {
            self.lastError = error.localizedDescription
            self.isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        bundleManager?.unloadAll()
        bundleManager = nil
        isRunning = false
        port = 0
    }

    func refreshStatus() {
        status = bundleManager?.status()
    }

    func unloadHeavyModels() {
        bundleManager?.unloadHeavyModels()
        refreshStatus()
    }

    private static func resolveModelsRoot(dataDirectory: URL) -> URL {
        let local = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("speech-coreml-v1", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return CoreMLBundleManager.defaultModelsRoot
    }
}
