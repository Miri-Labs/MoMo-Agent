import Foundation

public enum SpeechModelChoice: String, CaseIterable, Sendable {
    case senseVoice
    case funASRNano

    public func supports(_ language: SpeechLanguage) -> Bool {
        self == .senseVoice || language != .korean
    }
}

/// An immutable, verified download. The default model remains in the app bundle.
public struct DownloadedSpeechModel: Equatable, Sendable {
    public let directory: URL
    public let catalog: DownloadableSpeechModel

    public init(directory: URL, catalog: DownloadableSpeechModel) {
        self.directory = directory
        self.catalog = catalog
    }
}

public enum SpeechModelSelectionError: Error, Equatable, Sendable {
    case unsupportedLanguage
}

public enum SpeakerSegmentationModel: String, Codable, CaseIterable, Sendable {
    case diariZenWavLMBase
    case pyannoteCommunity1

    public var filename: String {
        switch self {
        case .diariZenWavLMBase: "diarizen-wavlm-base-s80-md.onnx"
        case .pyannoteCommunity1: "segmentation-community-1.onnx"
        }
    }

    public var sha256: String {
        switch self {
        case .diariZenWavLMBase: "ddc29bab8f9331ea26398becf6af5c57ff513f1f2d49200f68a5547799b3563a"
        case .pyannoteCommunity1: "62d59a487d8ba877d0bd1638c53aa06a810bdb104fb776a27ec2204521711006"
        }
    }
}
