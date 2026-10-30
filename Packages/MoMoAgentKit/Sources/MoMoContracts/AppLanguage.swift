import Foundation

/// Interface language is independent of the language spoken in a recording.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case chinese = "zh-Hans", english = "en", japanese = "ja", korean = "ko"

    public static func resolve(_ preferredLanguages: [String]) -> Self {
        for identifier in preferredLanguages {
            switch identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first {
            case "zh": return .chinese
            case "en": return .english
            case "ja": return .japanese
            case "ko": return .korean
            default: continue
            }
        }
        return .english
    }

    // System app-language changes restart the app; resolve once, outside streaming/meter updates.
    public static let current: Self = resolve(Bundle.main.preferredLocalizations + Locale.preferredLanguages)
    public static var resourceBundle: Bundle { .module }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var nativeName: String {
        switch self { case .chinese: "简体中文"; case .english: "English"; case .japanese: "日本語"; case .korean: "한국어" }
    }
    public var instructionName: String {
        switch self { case .chinese: "Simplified Chinese"; case .english: "English"; case .japanese: "Japanese"; case .korean: "Korean" }
    }
}
