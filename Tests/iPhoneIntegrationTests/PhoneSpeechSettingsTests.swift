import Foundation
import Testing
import MoMoContracts
@testable import MoMoAgent

@MainActor
@Test func earlyTranscriptHourDefaultsToEightAndLeavesLegacyPreferenceIntact() throws {
    let suite = "MoMoAgent.day-start-test.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }

    let settings = PhoneSpeechSettings(defaults: defaults)
    #expect(settings.dayStartHour == 8)
    #expect(settings.dayStartHourLabel == "08:00")
    #expect(defaults.object(forKey: DayStartBoundary.defaultsKey) == nil)

    var notifications: [Int] = []
    settings.onDayStartHourChanged = { notifications.append(settings.dayStartHour) }

    for hour in [0, 6, 23] {
        settings.selectDayStartHour(hour)
        #expect(settings.dayStartHour == hour)
        #expect(TranscriptReadingBoundary.resolvedHour(from: defaults) == hour)
        #expect(defaults.integer(forKey: PhoneSpeechSettings.dayStartHourKey) == hour)
        let restored = PhoneSpeechSettings(defaults: defaults)
        #expect(restored.dayStartHour == hour)
    }
    #expect(notifications == [0, 6, 23])

    settings.selectDayStartHour(24)
    #expect(settings.dayStartHour == 23)
    #expect(settings.failure != nil)

    settings.selectDayStartHour(PhoneSpeechSettings.defaultDayStartHour)
    #expect(settings.dayStartHour == 8)
    #expect(settings.dayStartHourLabel == "08:00")
    #expect(settings.failure == nil)
}
