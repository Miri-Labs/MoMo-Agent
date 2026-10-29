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
