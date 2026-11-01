import CryptoKit
import Foundation

/// Native relay-e2e/v1 initiator. Wire format and attribution: docs/implementation/relay-access.md.
struct RelayCipher {
    static let protocolName = "relay-e2e/v1"
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    private let code: String
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sent: UInt64 = 0
    private var received: UInt64?

    init(code: String) { self.code = code }

    static func routingToken(code: String) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: Data((protocolName + "/routing").utf8), info: Data(), outputByteCount: 16)
        return key.withUnsafeBytes { Data($0).relayBase64URL }
    }

    func hello() -> RelayFrame {
        RelayFrame(t: "hi", epk: privateKey.publicKey.x963Representation.relayBase64URL, n: nonce.relayBase64URL)
    }

    mutating func accept(_ frame: RelayFrame) throws -> RelayFrame {
        guard sendKey == nil, frame.t == "hi", let epk = frame.epk, let n = frame.n, let cr = frame.cr,
              let publicData = Data(relayBase64URL: epk), publicData.count == 65,
              let peerNonce = Data(relayBase64URL: n), peerNonce.count == 16,
              let confirmation = Data(relayBase64URL: cr), confirmation.count == 32 else { throw RelayError.authentication }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: publicData)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let transcript = Data(SHA256.hash(data: Data(Self.protocolName.utf8) + privateKey.publicKey.x963Representation + publicData + nonce + peerNonce))
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8), sharedInfo: Data((label + "|").utf8) + transcript, outputByteCount: 32)
        }
        let expected = key("confirm-r").withUnsafeBytes { Data($0) }
        var difference: UInt8 = 0
        for (a, b) in zip(expected, confirmation) { difference |= a ^ b }
        guard difference == 0 else { throw RelayError.authentication }
        sendKey = key("c2s"); receiveKey = key("s2c")
        return RelayFrame(t: "ok", ci: key("confirm-i").withUnsafeBytes { Data($0).relayBase64URL })
    }

    mutating func seal(_ frame: RelayFrame) throws -> Data {
        guard let sendKey, sent < UInt64.max else { throw RelayError.protocolFailure }
        var bigEndian = sent.bigEndian
        let iv = Data(repeating: 0, count: 4) + withUnsafeBytes(of: &bigEndian) { Data($0) }
        sent += 1
        let box = try AES.GCM.seal(JSONEncoder().encode(frame), using: sendKey, nonce: AES.GCM.Nonce(data: iv))
        return iv + box.ciphertext + box.tag
    }

    mutating func open(_ data: Data) throws -> RelayFrame {
        guard let receiveKey, data.count >= 28, data.prefix(4) == Data(repeating: 0, count: 4) else { throw RelayError.protocolFailure }
        let counter = data[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard received == nil || counter > received! else { throw RelayError.protocolFailure }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: receiveKey)
        received = counter
        return try JSONDecoder().decode(RelayFrame.self, from: plain)
    }
}

struct RelayFrame: Codable, Sendable {
    var t: String
    var id: String? = nil
    var epk: String? = nil
    var n: String? = nil
    var cr: String? = nil
    var ci: String? = nil
    var method: String? = nil
    var path: String? = nil
    var headers: [String: String]? = nil
    var b: String? = nil
    var status: Int? = nil
}

extension Data {
    var relayBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(relayBase64URL value: String) {
        self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

public enum RelayError: Error, LocalizedError, TransientTransportError {
    case invalidConfiguration, authentication, protocolFailure, requestTooLarge, unavailable
    public var isTransientTransportFailure: Bool { self == .unavailable }
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "中继配置无效，请重新扫描 Mac 配对码。"
        case .authentication: "中继加密验证失败，请重新配对。"
        case .protocolFailure: "中继加密连接异常，已停止传输。"
        case .requestTooLarge: "此请求超过中继的 512 KB 限制，请使用 Tailscale 传输。"
        case .unavailable: "暂时无法通过中继连接 Mac，请稍后重试。"
        }
    }
}
