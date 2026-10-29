import SwiftUI
import MoMoAgentClient
import MoMoAgentRTC
@preconcurrency import WebRTC

@MainActor @Observable
final class PhoneDesktopSession {
    let client: AgentClient
    let tailnet: EmbeddedTailnet
    var status: DesktopStatus?
    var videoTrack: RTCVideoTrack?
    var videoSize = CGSize.zero
    var connectionFailure: String?
    var inputFailure: String?
    var changingControl = false
    var needsPairing = false
    private var connected = false
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var rtc: DesktopRTC?
    @ObservationIgnored private var media: DesktopMediaRoute?
    @ObservationIgnored private var lastFrameAt: TimeInterval = 0
    var failure: String? { inputFailure ?? connectionFailure }
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputTaskID: UUID?
    @ObservationIgnored private var inputs: [DesktopInput] = []
    @ObservationIgnored private var inputSequence = 0
    @ObservationIgnored private var sequenceEpoch = -1
    var hasLivePicture: Bool { connected && videoTrack != nil && ProcessInfo.processInfo.systemUptime - lastFrameAt < 5 }
    var canControl: Bool { hasLivePicture && status?.owner == "you" && status?.active == true && status?.input == true && failure == nil && !changingControl }
    init(client: AgentClient, tailnet: EmbeddedTailnet) { self.client = client; self.tailnet = tailnet }

    func observe() async {
        let id = UUID(); observationID = id
        defer { if observationID == id { observationID = nil; suspend() } }
        while active(id) {
            do {
                let current = try await client.desktopStatus()
                guard active(id) else { return }
                apply(current)
                if current.approved, current.screen, current.owner != "other" {
                    try await connectVideo(id)
                }
            } catch { if active(id) { connectionFailed(error) } }
            guard observationID == id else { return }
            await closeVideo()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    private func active(_ id: UUID) -> Bool { observationID == id && !Task.isCancelled && !needsPairing }
    private func connectVideo(_ id: UUID) async throws {
        let peer = try DesktopRTC(sending: false); rtc = peer
        let route = try await DesktopMediaRoute.open(tailnet)
        guard active(id) else { peer.close(); await route.close(); throw CancellationError() }
        media = route
        let local = try await peer.localDescription()
        tailnet.diagnostics.recordVideo("offer")
        let answer = try await client.desktopVideoOffer(DesktopVideoSignal(sdp: route.advertised(local)))
        guard active(id) else { throw CancellationError() }
        try await route.bind(local: local, remote: answer.sdp)
        try await peer.remoteDescription(route.received(answer.sdp), answer: true)
        try await peer.waitForControl()
        tailnet.diagnostics.recordVideo("control-ready")
        apply(try await control("status"))
        if status?.owner == "you", status?.active == true, let session = status?.session { try await reset(session) }
        var checked = ProcessInfo.processInfo.systemUptime
        var heartbeat = checked
        var reported = checked
        var firstFrame = true
        let firstFrameDeadline = checked + 10
        while active(id), rtc === peer {
            guard peer.controlReady else { throw DesktopRTCError.closed }
            let frame = peer.frames.snapshot(), now = ProcessInfo.processInfo.systemUptime
            if frame.count > 0 {
                if videoTrack !== peer.videoTrack { videoTrack = peer.videoTrack }
                if videoSize != frame.size { videoSize = frame.size }
                if firstFrame { tailnet.diagnostics.recordVideo("first-frame"); firstFrame = false }
                lastFrameAt = frame.time
                guard now - frame.time < 5 else { throw DesktopRTCError.timeout }
                connected = true; connectionFailure = nil
            } else if now > firstFrameDeadline { throw DesktopRTCError.timeout }
            if now - reported >= 5 { tailnet.diagnostics.recordVideo("playing", statistics: await peer.statistics()); reported = now }
            if now - checked >= 3 {
                apply(try await control("status")); checked = now
                guard status?.approved == true, status?.screen == true, status?.owner != "other" else { return }
            }
            if now - heartbeat >= 5, status?.owner == "you", status?.active == true, let session = status?.session {
                apply(try await control("heartbeat", session: session)); heartbeat = now
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func apply(_ current: DesktopStatus) {
        guard current.epoch >= (status?.epoch ?? 0) else { return }
        if sequenceEpoch != current.epoch { sequenceEpoch = current.epoch; inputSequence = 0 }
        inputSequence = max(inputSequence, current.input_sequence ?? 0)
        if status?.session != current.session || !current.active { stopInput() }
        status = current
    }
    private func control(_ operation: String, session: String? = nil, requestID: UUID? = nil) async throws -> DesktopStatus {
        guard let rtc else { throw DesktopRTCError.closed }
        var payload: [String: String] = [:]
        if let session { payload["session"] = session }
        if let requestID { payload["request_id"] = requestID.uuidString }
        return try JSONDecoder().decode(DesktopStatus.self, from: await rtc.request(operation, body: JSONEncoder().encode(payload)))
    }
    private func sendInput(_ event: DesktopInput, session: String) async throws {
        guard let rtc else { throw DesktopRTCError.closed }
        struct Input: Encodable { let session: String; let event_id: UUID; let event: DesktopInput }
        _ = try await rtc.request("input", body: JSONEncoder().encode(Input(session: session, event_id: UUID(), event: event)))
    }
    func changeControl(returning: Bool = false) async {
        guard !changingControl, status?.owner == "you" || hasLivePicture else { return }
        changingControl = true; defer { changingControl = false }
        do {
            if status?.owner == "you", status?.active == true || returning, let session = status?.session {
                stopInput(); apply(try await control("release", session: session))
            } else {
                apply(try await control("claim", requestID: UUID()))
                if let session = status?.session { try await reset(session) }
            }
            inputFailure = nil; connectionFailure = nil
        } catch { connectionFailed(error) }
    }
    func send(_ event: DesktopInput) {
        guard canControl else { return }
        var event = event; inputSequence += 1; event.sequence = inputSequence
        if event.kind == "mouse_move", inputs.last?.kind == "mouse_move" { inputs[inputs.count - 1] = event }
        else if event.kind == "scroll", inputs.last?.kind == "scroll" {
            var merged = event
            merged.delta = max(-1000, min(1000, (inputs.last?.delta ?? 0) + (event.delta ?? 0)))
            merged.delta_x = max(-1000, min(1000, (inputs.last?.delta_x ?? 0) + (event.delta_x ?? 0)))
            inputs[inputs.count - 1] = merged
        } else {
            guard inputs.count < 128 else { inputFailure = String(localized: "输入过快，已暂停。请重新连接后继续。"); rtc?.close(); return }
            inputs.append(event)
        }
        guard inputTask == nil else { return }
        let id = UUID(); inputTaskID = id
        inputTask = Task {
            defer { if inputTaskID == id { inputTask = nil; inputTaskID = nil } }
            while !inputs.isEmpty, !Task.isCancelled, let session = status?.session, canControl {
                let input = inputs.removeFirst()
                do { try await sendInput(input, session: session) }
                catch {
                    if !Task.isCancelled { inputFailure = String(localized: "操作结果未确认，请查看桌面后重新连接。"); rtc?.close() }
                    break
                }
            }
        }
    }

    func reconnect() async {
        inputFailure = nil; connectionFailure = nil
        rtc?.close()
        do { apply(try await client.desktopStatus()) } catch { connectionFailed(error) }
    }
    func suspend() {
        observationID = nil; connected = false; stopInput()
        let peer = rtc, route = media
        rtc = nil; media = nil; videoTrack = nil; videoSize = .zero
        // Explicitly release held keys before closing when the channel is usable.
        // The Mac input lease watchdog also releases them after network loss.
        let session = status?.owner == "you" ? status?.session : nil
        inputSequence += 1
        var event = DesktopInput(kind: "reset"); event.sequence = inputSequence
        Task {
            if let peer, peer.controlReady, let session {
                struct Input: Encodable { let session: String; let event_id: UUID; let event: DesktopInput }
                if let body = try? JSONEncoder().encode(Input(session: session, event_id: UUID(), event: event)) { _ = try? await peer.request("input", body: body) }
            }
            peer?.close(); await route?.close()
        }
    }
    private func closeVideo() async {
        let peer = rtc, route = media
        rtc = nil; media = nil; connected = false; videoTrack = nil; videoSize = .zero
        stopInput(); peer?.close(); await route?.close()
    }
    private func reset(_ session: String) async throws {
        inputSequence += 1; var event = DesktopInput(kind: "reset"); event.sequence = inputSequence
        try await sendInput(event, session: session)
    }
    private func connectionFailed(_ error: Error) {
        let code = error as NSError
        tailnet.diagnostics.recordVideo("failed", statistics: ["domain": code.domain, "code": String(code.code)])
        if let error = error as? AgentClientError, case let .http(status, code, _, _) = error,
           status == 401 || code == "device_revoked" {
            needsPairing = true; connectionFailure = String(localized: "配对已失效")
        } else { connectionFailure = String(localized: "连接中断，正在重连") }
        connected = false; stopInput(); rtc?.close()
    }
    private func stopInput() { inputTaskID = nil; inputTask?.cancel(); inputTask = nil; inputs.removeAll() }
}
