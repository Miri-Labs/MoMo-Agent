import Foundation
import MoMoContracts

public struct SpeechModelManifest: Codable, Equatable, Sendable {
    public static let sherpaVersion = "1.13.8"
    public static let sherpaCommit = "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"
    public static let ortVersion = "1.28.2"
    public let schemaVersion: Int
    public let asrSHA256: String
    public let tokensSHA256: String
    public let vadSHA256: String

    public init(asrSHA256: String, tokensSHA256: String, vadSHA256: String) throws {
        schemaVersion = 1
        self.asrSHA256 = asrSHA256; self.tokensSHA256 = tokensSHA256; self.vadSHA256 = vadSHA256
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, [asrSHA256, tokensSHA256, vadSHA256].allSatisfy(ContentHash.isValid) else {
            throw SpeechError.invalidModelManifest
        }
    }
}

public struct SpeechModelBundle: Sendable {
    public let directory: URL
    public let manifest: SpeechModelManifest
    public init(directory: URL, manifest: SpeechModelManifest) {
        self.directory = directory; self.manifest = manifest
    }

    public static func load(from directory: URL) throws -> Self {
        let manifest = try WireJSON.decode(SpeechModelManifest.self,
                                          from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        try manifest.validate()
        return Self(directory: directory, manifest: manifest)
    }

    public func validate() throws {
        try validate(attempt: nil, recorder: nil)
    }

    func validate(attempt: SpeechAttempt?, recorder: SpeechDiagnosticRecorder?) throws {
        try manifest.validate()
        for (name, hash) in [("model.int8.onnx", manifest.asrSHA256), ("tokens.txt", manifest.tokensSHA256),
                             ("silero_vad.onnx", manifest.vadSHA256)] {
            guard try speechFileHash(directory.appendingPathComponent(name), attempt: attempt, recorder: recorder, model: true) == hash else {
                throw SpeechError.modelHashMismatch(name)
            }
        }
    }

    public func fingerprint(configuration: SpeechConfiguration,
                            rule: String = SpeechConfiguration.analysisRuleVersion) throws -> String {
        try manifest.validate(); try configuration.validate()
        struct Identity: Encodable {
            let manifest: SpeechModelManifest
            let configuration: SpeechConfiguration
            let sherpa = SpeechModelManifest.sherpaCommit
            let ort = SpeechModelManifest.ortVersion
            let rule: String
            let sampleRate = SpeechConfiguration.sampleRate
            let vadFrameSize = SpeechConfiguration.vadFrameSize
        }
        return ContentHash.sha256(try WireJSON.encode(Identity(manifest: manifest, configuration: configuration, rule: rule)))
    }
}
