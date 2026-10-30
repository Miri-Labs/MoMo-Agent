import AVFAudio
import Foundation

enum EarphoneRouteMode: Equatable, Sendable {
    /// HFP: the earphone microphone is the input and its audio is saved.
    case headset
    /// A2DP: other apps keep hi-fi output; the built-in microphone only keeps the session alive.
    case standby
}

enum EarphoneRouteError: LocalizedError, Equatable {
    case permissionDenied, headsetUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "请允许 MoMo Agent 使用麦克风，才能用耳机录音。")
        case .headsetUnavailable: String(localized: "没有可用的蓝牙耳机麦克风。")
        }
    }
}

enum EarphoneRouteEvent: Equatable, Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool), mediaServicesReset
}

/// The audio tap reads this fixed-size gate, never AVAudioSession. Route notifications close it
/// synchronously, so built-in microphone samples can never reach an earphone segment.
final class EarphoneInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var headset = false
    private var interrupted = false

    func allowsInput() -> Bool { lock.withLock { headset && !interrupted } }
    var interruptionActive: Bool { lock.withLock { interrupted } }

    fileprivate func setHeadsetSelected(_ selected: Bool) { lock.withLock { headset = selected } }
    fileprivate func setInterrupted(_ value: Bool) { lock.withLock { interrupted = value } }
}

/// Owns the shared AVAudioSession while earphone capture runs. Every switch deactivates the session
/// first: in the background iOS refuses a category change on an active session ('!int'), and an
/// HFP-capable category keeps output on HFP even when the built-in microphone is preferred.
@MainActor
final class EarphoneAudioRoute {
    private static let operationQueue = DispatchQueue(label: "com.momoagent.ios.earphone-route")
    nonisolated private static let headsetLinkTimeout: TimeInterval = 2
    let gate = EarphoneInputGate()
    var onEvent: (@MainActor (EarphoneRouteEvent) -> Void)?
    var onHint: (@MainActor () -> Void)?
    private(set) var mode: EarphoneRouteMode?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let gate = gate
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            gate.setHeadsetSelected(Self.isHeadsetInputSelected())
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let event: EarphoneRouteEvent = type == .began ? .interruptionBegan
                : .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
            if type == .began { gate.setInterrupted(true) }
            Task { @MainActor [weak self] in
                if case .interruptionEnded = event { gate.setInterrupted(false) }
                self?.handle(event)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            gate.setHeadsetSelected(false)
            Task { @MainActor [weak self] in self?.handle(.mediaServicesReset) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onHint?() }
        })
    }

    private func handle(_ event: EarphoneRouteEvent) {
        // An interruption or reset leaves the session inactive; the next switch must reactivate it.
        mode = nil
        onEvent?(event)
    }

    /// Any other app's audio, including video, podcasts and navigation prompts.
    var otherAudioPlaying: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
    }

    /// In standby only A2DP output is visible, so a connected headset is recognized by its output too.
    var connectedHeadsetName: String? {
        let session = AVAudioSession.sharedInstance()
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        if let input = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) { return input.portName }
        return session.currentRoute.outputs.first { bluetooth.contains($0.portType) }?.portName
    }

    /// A new user-visible attempt; a later interruption still closes the gate again.
    func resetInterruption() { gate.setInterrupted(false) }

    func requestPermission() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw EarphoneRouteError.permissionDenied }
    }

    /// Blocking session calls run on a serial queue. A failed switch leaves `mode` nil so the caller
    /// knows the session must be configured again.
    func configure(_ next: EarphoneRouteMode) async throws {
        let wasActive = mode != nil
        mode = nil
        let gate = gate
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.operationQueue.async { @Sendable in
                do {
                    let session = AVAudioSession.sharedInstance()
                    var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
                    options.insert(next == .headset ? .allowBluetoothHFP : .allowBluetoothA2DP)
                    if wasActive { try session.setActive(false, options: .notifyOthersOnDeactivation) }
                    try session.setCategory(.playAndRecord, mode: .default, options: options)
                    try session.setActive(true)
                    let wanted: AVAudioSession.Port = next == .headset ? .bluetoothHFP : .builtInMic
                    // The HFP input appears, and becomes the route, only after the earphone's voice link
                    // is up, which can lag activation by several hundred milliseconds.
                    let deadline = ProcessInfo.processInfo.systemUptime + Self.headsetLinkTimeout
                    var preferred = session.availableInputs?.first { $0.portType == wanted }
                    while next == .headset, preferred == nil, ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        preferred = session.availableInputs?.first { $0.portType == wanted }
                    }
                    if next == .headset, preferred == nil { throw EarphoneRouteError.headsetUnavailable }
                    try session.setPreferredInput(preferred)
                    var selected = Self.isHeadsetInputSelected()
                    while next == .headset, !selected, ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        selected = Self.isHeadsetInputSelected()
                    }
                    gate.setHeadsetSelected(selected)
                    if next == .headset, !gate.allowsInput() { throw EarphoneRouteError.headsetUnavailable }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        mode = next
    }

    func deactivate() async throws {
        mode = nil
        gate.setHeadsetSelected(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.operationQueue.async { @Sendable in
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Port types only, for the diagnostic log; device names stay out of it.
    var routeDescription: String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let available = (session.availableInputs ?? []).map(\.portType.rawValue).joined(separator: ",")
        return "in[\(inputs)] out[\(outputs)] available[\(available)]"
    }

    nonisolated private static func isHeadsetInputSelected() -> Bool {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return !inputs.isEmpty && inputs.allSatisfy { $0.portType == .bluetoothHFP }
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
