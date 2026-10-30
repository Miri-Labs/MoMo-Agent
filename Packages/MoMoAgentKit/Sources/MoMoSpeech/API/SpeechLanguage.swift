import Foundation

public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case automatic = "auto"
    case mandarin = "zh"
    case cantonese = "yue"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
}
