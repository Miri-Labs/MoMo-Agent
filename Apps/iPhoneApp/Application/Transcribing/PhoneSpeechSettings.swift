import Foundation
import Observation
import MoMoSpeech

@MainActor @Observable
final class PhoneSpeechSettings {
    static let languageKey = "speech.recognitionLanguage"
    static let vadThresholdKey = "speech.vadThreshold"
    static let defaultVADThreshold = 0.25
    static let vadThresholdRange = 0.05...0.95
    private(set) var language: SpeechLanguage
    private(set) var vadThreshold: Double
    private(set) var failure: String?
    let models: PhoneSpeechModelSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let speech: SpeechEngine?

    init(speech: SpeechEngine?, defaults: UserDefaults = .standard, modelDirectory: URL? = nil) {
        self.speech = speech
        self.defaults = defaults
        models = PhoneSpeechModelSettings(speech: speech, directory: modelDirectory ??
            URL.applicationSupportDirectory.appendingPathComponent("MoMoAgent/SpeechModels"), defaults: defaults)
        language = defaults.string(forKey: Self.languageKey).flatMap(SpeechLanguage.init(rawValue:)) ?? .automatic
        let saved = defaults.object(forKey: Self.vadThresholdKey) as? NSNumber
        let value = saved?.doubleValue ?? Self.defaultVADThreshold
        vadThreshold = value.isFinite && Self.vadThresholdRange.contains(value) ? value : Self.defaultVADThreshold
        do { try speech?.setRecognitionLanguage(language) }
        catch { failure = String(localized: "识别语言未生效，请重新选择。") }
        // Keep Archive's established configuration identity; changing a preference must not rescan history.
        do { try speech?.setVoiceActivityThreshold(Float(vadThreshold)) }
        catch { failure = String(localized: "语音检测设置未生效，请重试。") }
    }

    func select(_ language: SpeechLanguage) {
        guard self.language != language else { return }
        guard models.choice.supports(language) else {
            failure = String(localized: "FunASR 不支持韩语，请先切换到 SenseVoice。")
            return
        }
        do {
            try speech?.setRecognitionLanguage(language)
            failure = nil
            self.language = language
            defaults.set(language.rawValue, forKey: Self.languageKey)
        } catch { failure = String(localized: "当前模型不支持这个语言，请先切换模型。") }
    }

    func selectVADThreshold(_ value: Double) {
        guard value.isFinite, Self.vadThresholdRange.contains(value) else {
            failure = String(localized: "语音检测阈值须在 0.05 至 0.95 之间。")
            return
        }
        let rounded = (value * 100).rounded() / 100
        do {
            try speech?.setVoiceActivityThreshold(Float(rounded))
            vadThreshold = rounded
            defaults.set(rounded, forKey: Self.vadThresholdKey)
            failure = nil
        } catch { failure = String(localized: "语音检测设置未生效，请重试。") }
    }
}

extension SpeechLanguage {
    var title: String {
        switch self {
        case .automatic: String(localized: "自动识别")
        case .mandarin: String(localized: "普通话")
        case .cantonese: String(localized: "粤语")
        case .english: String(localized: "英语")
        case .japanese: String(localized: "日语")
        case .korean: String(localized: "韩语")
        }
    }
}
