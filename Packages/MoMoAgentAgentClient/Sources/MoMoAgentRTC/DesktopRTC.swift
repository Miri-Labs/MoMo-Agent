import Foundation
@preconcurrency import WebRTC

public struct DesktopControlPacket: Codable, Sendable {
    public let id: UUID
    public let operation: String
    public let body: Data
    public init(id: UUID = UUID(), operation: String, body: Data) { self.id = id; self.operation = operation; self.body = body }
}
private struct DesktopControlReply: Codable { let id: UUID; let status: Int; let body: Data }

/// The video and control channel have one lifecycle, separate from chat. No
/// screenshot bytes pass through HTTP or the ordered input DataChannel.
@MainActor public final class DesktopRTC: NSObject {
    public private(set) var videoTrack: RTCVideoTrack?
    public var onTrack: ((RTCVideoTrack) -> Void)?
    public var onClose: (() -> Void)?
    public var handleControl: ((DesktopControlPacket) async -> (Int, Data))?
    public var controlReady: Bool { channel?.readyState == .open && !closed }
    public let frames = DesktopVideoFrames()
    public private(set) var source: RTCVideoSource?
    public private(set) var capturer: RTCVideoCapturer?
    private var outgoingTrack: RTCVideoTrack?
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var closed = false
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var incoming: [DesktopControlPacket] = []
    private var inputWorker: Task<Void, Never>?
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        if let codec = RTCDefaultVideoEncoderFactory.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = codec }
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    public init(sending: Bool) throws {
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        guard let created = Self.factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else { throw DesktopRTCError.unavailable }
        peer = created
        if sending {
            let source = Self.factory.videoSource(forScreenCast: true)
            self.source = source; capturer = RTCVideoCapturer(delegate: source)
            outgoingTrack = Self.factory.videoTrack(with: source, trackId: "desktop")
        } else {
            let options = RTCRtpTransceiverInit(); options.direction = .recvOnly
            guard let transceiver = peer.addTransceiver(of: .video, init: options) else { throw DesktopRTCError.unavailable }
            try configureVideo(transceiver)
            let channelOptions = RTCDataChannelConfiguration(); channelOptions.isOrdered = true
            channel = peer.dataChannel(forLabel: "momo-desktop-v1", configuration: channelOptions)
            channel?.delegate = self
        }
    }
    private func configureVideo(_ transceiver: RTCRtpTransceiver) throws {
        let codecs = Self.factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter { $0.mimeType.lowercased() == "video/h264" }
        guard !codecs.isEmpty else { throw DesktopRTCError.remote(503, "H.264 codec unavailable") }
        try transceiver.setCodecPreferences(codecs, error: ())
        let parameters = transceiver.sender.parameters
        for encoding in parameters.encodings { encoding.maxBitrateBps = 4_000_000; encoding.maxFramerate = 30 }
        transceiver.sender.parameters = parameters
    }
    public func localDescription(answer: Bool = false) async throws -> String {
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { value, error in
                if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? DesktopRTCError.invalidSignal) }
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if answer { peer.answer(for: constraints, completionHandler: callback) } else { peer.offer(for: constraints, completionHandler: callback) }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        for _ in 0..<100 {
            try Task.checkCancellation(); guard !closed else { throw DesktopRTCError.closed }
            if let sdp = peer.localDescription?.sdp, (try? DesktopSDP.endpoint(sdp)) != nil { return sdp }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DesktopRTCError.timeout
    }
    public func remoteDescription(_ sdp: String, answer: Bool) async throws {
        guard !closed else { throw DesktopRTCError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: answer ? .answer : .offer, sdp: sdp)) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        if !answer, let outgoingTrack {
            guard let transceiver = peer.transceivers.first(where: { $0.mediaType == .video }) else { throw DesktopRTCError.invalidSignal }
            transceiver.sender.track = outgoingTrack
            transceiver.sender.streamIds = ["desktop"]
            var directionError: NSError?
            transceiver.setDirection(.sendOnly, error: &directionError)
            if let directionError { throw directionError }
            try configureVideo(transceiver)
        }
    }
    public func waitForControl() async throws {
        for _ in 0..<200 {
            try Task.checkCancellation(); guard !closed else { throw DesktopRTCError.closed }
            if controlReady { return }; try await Task.sleep(for: .milliseconds(50))
        }
        throw DesktopRTCError.timeout
    }
    public func request(_ operation: String, body: Data = Data("{}".utf8)) async throws -> Data {
        let packet = DesktopControlPacket(operation: operation, body: body)
        let data = try JSONEncoder().encode(packet)
        guard controlReady, data.count <= 32768, pending.count < 32, let channel, channel.bufferedAmount < 65536 else { throw DesktopRTCError.unavailable }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[packet.id] = continuation
                deadlines[packet.id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    self?.finish(packet.id, result: .failure(DesktopRTCError.timeout))
                }
                if !channel.sendData(RTCDataBuffer(data: data, isBinary: false)) { finish(packet.id, result: .failure(DesktopRTCError.closed)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(packet.id, result: .failure(CancellationError())) } }
    }
    private func finish(_ id: UUID, result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func receive(_ data: Data) {
        guard !closed, data.count <= 32768 else { close(); return }
        if let handler = handleControl {
            guard let packet = try? JSONDecoder().decode(DesktopControlPacket.self, from: data), incoming.count < 128 else { close(); return }
            incoming.append(packet)
            guard inputWorker == nil else { return }
            inputWorker = Task { [weak self] in
                guard let self else { return }
                defer { self.inputWorker = nil }
                while !self.incoming.isEmpty, !self.closed, !Task.isCancelled {
                    let request = self.incoming.removeFirst()
                    let (status, result) = await handler(request)
                    guard !self.closed, result.count <= 20000,
                          let encoded = try? JSONEncoder().encode(DesktopControlReply(id: request.id, status: status, body: result)),
                          self.channel?.sendData(RTCDataBuffer(data: encoded, isBinary: false)) == true else { self.close(); return }
                }
            }
        } else if let reply = try? JSONDecoder().decode(DesktopControlReply.self, from: data) {
            if reply.status == 200 { finish(reply.id, result: .success(reply.body)) }
            else {
                let error = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
                let message = (error?["error"] as? [String: Any])?["message"] as? String ?? "电脑操作未完成。"
                finish(reply.id, result: .failure(DesktopRTCError.remote(reply.status, message)))
            }
        } else { close() }
    }
    public func statistics() async -> [String: String] {
        guard !closed else { return [:] }
        return await withCheckedContinuation { c in
            peer.statistics { report in
                var result: [String: String] = [:]
                for item in report.statistics.values where ["inbound-rtp", "outbound-rtp", "codec", "media-source"].contains(item.type) {
                    for key in ["frames", "framesDecoded", "framesEncoded", "bytesSent", "bytesReceived", "mimeType", "frameWidth", "frameHeight", "framesPerSecond", "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder", "totalEncodeTime"] {
                        if let v = item.values[key] { result[item.type + "." + key] = String(describing: v) }
                    }
                }
                c.resume(returning: result)
            }
        }
    }
    public func close() {
        guard !closed else { return }; closed = true
        inputWorker?.cancel(); incoming.removeAll()
        for id in Array(pending.keys) { finish(id, result: .failure(DesktopRTCError.closed)) }
        videoTrack?.remove(frames); videoTrack = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close()
        source = nil; capturer = nil; outgoingTrack = nil
        onClose?(); onClose = nil
    }
}

public final class DesktopVideoFrames: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var value: (count: Int, size: CGSize, time: TimeInterval) = (0, .zero, 0)
    public func snapshot() -> (count: Int, size: CGSize, time: TimeInterval) { lock.withLock { value } }
    public func setSize(_ size: CGSize) {}
    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock { value = (value.count + 1, CGSize(width: Int(frame.width), height: Int(frame.height)), ProcessInfo.processInfo.systemUptime) }
    }
}
extension DesktopRTC: RTCDataChannelDelegate {
    nonisolated public func dataChannelDidChangeState(_ channel: RTCDataChannel) {
        if channel.readyState == .closed { Task { @MainActor [weak self] in self?.close() } }
    }
    nonisolated public func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in self?.receive(data) }
    }
}
extension DesktopRTC: RTCPeerConnectionDelegate {
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if [.failed, .closed].contains(newState) { Task { @MainActor [weak self] in self?.close() } }
    }
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didOpen channel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.channel == nil, channel.label == "momo-desktop-v1" else { channel.close(); return }
            self.channel = channel; channel.delegate = self
        }
    }
    nonisolated public func peerConnection(_ p: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.videoTrack = track; track.add(self.frames); self.onTrack?(track)
        }
    }
}
