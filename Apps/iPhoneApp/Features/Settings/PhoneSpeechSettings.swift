import Foundation
import Observation
import MoMoArchive
import MoMoContracts

/// Minimal iPhone-side reading boundary preference (`dayStartHour`).
/// All speech transcription, VAD, language, and speaker lock settings now live on Mac
/// and are remotely controlled via `MacSpeechSettingsView`.
@MainActor @Observable
final class PhoneSpeechSettings {
    static let dayStartHourKey = TranscriptReadingBoundary.defaultsKey
    static let defaultDayStartHour = TranscriptReadingBoundary.defaultHour
    static let dayStartHourRange = TranscriptReadingBoundary.hourRange

    private(set) var dayStartHour: Int
    private(set) var failure: String?
    @ObservationIgnored var onDayStartHourChanged: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    var dayStartHourLabel: String {
        TranscriptReadingBoundary.label(for: dayStartHour)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dayStartHour = TranscriptReadingBoundary.resolvedHour(from: defaults)
    }

    func selectDayStartHour(_ value: Int) {
        guard Self.dayStartHourRange.contains(value) else {
            failure = String(localized: "凌晨记录默认折叠至须在 00:00 至 23:00 之间。")
            return
        }
        let changed = dayStartHour != value
        dayStartHour = value
        defaults.set(value, forKey: Self.dayStartHourKey)
        failure = nil
        if changed { onDayStartHourChanged?() }
    }
}
