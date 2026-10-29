import AVFAudio
import Foundation

enum WatchAudioSessionError: LocalizedError, Equatable {
    case permissionDenied, builtInMicrophoneUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "请允许 MoMo Agent 使用手表麦克风。")
        case .builtInMicrophoneUnavailable: String(localized: "手表自带麦克风暂不可用，未改用耳机录音。请稍后重试。")
        }
    }
}

enum WatchAudioEvent: Equatable, Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: UInt, builtInMicrophoneSelected: Bool)
    case mediaServicesReset
}

/// The audio callback reads a fixed-size gate, never AVAudioSession or a device name.
/// Route notifications close it synchronously, before their MainActor recovery work.
final class WatchMicrophoneGate: @unchecked Sendable {
    struct ActivationObservation: Sendable {
        fileprivate let activation: UInt64
        fileprivate let revision: UInt64
    }

    private let lock = NSLock()
    private var enabled = false
    private var builtIn = false
    private var interrupted = false
    private var activation: UInt64 = 0
    private var revision: UInt64 = 0
    private var events: [WatchAudioEvent] = []

    func beginActivation(recoverInterruptedSession: Bool = false) -> UInt64 {
        lock.withLock {
            activation += 1; revision += 1; enabled = false
            // An interruption is not guaranteed to deliver an end notification. A user retry
            // may attempt activation again; a NEW interruption still invalidates this attempt.
            if recoverInterruptedSession { interrupted = false }
            return activation
        }
    }

    func activationObservation(for attempt: UInt64) -> ActivationObservation? {
        lock.withLock {
            guard activation == attempt, !interrupted else { return nil }
            return ActivationObservation(activation: activation, revision: revision)
        }
    }

    func confirmActivation(_ observation: ActivationObservation, builtIn selected: Bool) -> Bool {
        lock.withLock {
            guard activation == observation.activation, revision == observation.revision, !interrupted else { return false }
            builtIn = selected
            enabled = selected
            return selected
        }
    }

    func beginRouteObservation() -> UInt64 {
        lock.withLock { revision += 1; return revision }
    }

    @discardableResult
    func commitRouteObservation(_ observation: UInt64, builtIn selected: Bool, reason: UInt) -> Bool {
        lock.withLock {
            guard revision == observation else { return false }
            builtIn = selected
            if !selected { enabled = false }
            events.append(.routeChanged(reason: reason, builtInMicrophoneSelected: selected))
            return true
        }
    }

    func interruptionBegan() {
        lock.withLock {
            activation += 1; revision += 1; interrupted = true; enabled = false
            events.append(.interruptionBegan)
        }
    }

    func interruptionEnded(shouldResume: Bool) {
        lock.withLock {
            revision += 1; interrupted = false
            events.append(.interruptionEnded(shouldResume: shouldResume))
        }
    }

    func mediaServicesReset() {
        lock.withLock {
            activation += 1; revision += 1; enabled = false; builtIn = false; interrupted = false
            events.append(.mediaServicesReset)
        }
    }

    func deactivate() {
        lock.withLock { activation += 1; revision += 1; enabled = false }
    }

    /// State and notification order are committed together; delivery never holds the tap's lock.
    func takeEvents() -> [WatchAudioEvent] {
        lock.withLock {
            let pending = events
            events = []
            return pending
        }
    }

    func allowsInput() -> Bool { lock.withLock { enabled && builtIn && !interrupted } }
    var builtInMicrophoneSelected: Bool { lock.withLock { builtIn } }
    var interruptionActive: Bool { lock.withLock { interrupted } }
}

@MainActor
final class WatchAudioSession {
    private static let operationQueue = DispatchQueue(label: "com.momoagent.watch.audio-session")
    let microphoneGate = WatchMicrophoneGate()
    var onEvent: (@MainActor (WatchAudioEvent) async -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var deliveringEvents = false
    private var closed = false

    init() {
        let center = NotificationCenter.default
        let gate = microphoneGate
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if type == .began { gate.interruptionBegan() }
            else { gate.interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)) }
            Task { @MainActor [weak self] in await self?.deliverPendingEvents() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            let observation = gate.beginRouteObservation()
            let builtIn = Self.isBuiltInMicrophoneSelected()
            guard gate.commitRouteObservation(observation, builtIn: builtIn, reason: raw) else { return }
            Task { @MainActor [weak self] in await self?.deliverPendingEvents() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            gate.mediaServicesReset()
            Task { @MainActor [weak self] in await self?.deliverPendingEvents() }
        })
    }

    private func deliverPendingEvents() async {
        guard !closed, !deliveringEvents else { return }
        deliveringEvents = true
        defer { deliveringEvents = false }
        while !closed {
            let events = microphoneGate.takeEvents()
            guard !events.isEmpty else { return }
            for event in events {
                guard !closed else { return }
                await onEvent?(event)
            }
        }
    }

    nonisolated private static func isBuiltInMicrophoneSelected() -> Bool {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return !inputs.isEmpty && inputs.allSatisfy { $0.portType == .builtInMic }
    }

    func activate(recoverInterruptedSession: Bool = false) async throws {
        let attempt = microphoneGate.beginActivation(recoverInterruptedSession: recoverInterruptedSession)
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw WatchAudioSessionError.permissionDenied }
        let gate = microphoneGate
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.operationQueue.async { @Sendable in
                do {
                    let session = AVAudioSession.sharedInstance()
                    // watchOS explicitly makes setPreferredInput unavailable. Exclude all Bluetooth
                    // input options and require the actual selected route to be the built-in mic.
                    try session.setCategory(.record, mode: .default, options: [])
                    var lastPriorityError: (any Error)?
                    for attemptIndex in 0..<4 {
                        do {
                            try session.setActive(true)
                            lastPriorityError = nil
                            break
                        } catch {
                            if Self.microphoneIsOccupied(error), attemptIndex < 3 {
                                lastPriorityError = error
                                usleep(250_000)
                                continue
                            }
                            throw error
                        }
                    }
                    if let lastPriorityError { throw lastPriorityError }
                    guard let observation = gate.activationObservation(for: attempt) else {
                        throw WatchAudioSessionError.builtInMicrophoneUnavailable
                    }
                    let builtIn = Self.isBuiltInMicrophoneSelected()
                    guard gate.confirmActivation(observation, builtIn: builtIn) else {
                        throw WatchAudioSessionError.builtInMicrophoneUnavailable
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func microphoneIsOccupied(_ error: any Error) -> Bool {
        let native = error as NSError
        return native.domain == NSOSStatusErrorDomain
            && native.code == Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue)
    }

    func deactivate() async throws {
        microphoneGate.deactivate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.operationQueue.async { @Sendable in
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() {
        closed = true
        microphoneGate.deactivate()
        _ = microphoneGate.takeEvents()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
