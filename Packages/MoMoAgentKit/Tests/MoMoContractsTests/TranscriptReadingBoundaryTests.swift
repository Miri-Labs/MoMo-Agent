import Foundation
import Testing
@testable import MoMoContracts

struct TranscriptReadingBoundaryTests {
    @Test func preferenceDoesNotReuseOrWriteLegacyDayOwnership() throws {
        let name = "transcript-reading-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for legacyHour in [0, 8, 23] {
            defaults.set(legacyHour, forKey: DayStartBoundary.defaultsKey)
            #expect(TranscriptReadingBoundary.resolvedHour(from: defaults) == 8)
            #expect(defaults.integer(forKey: DayStartBoundary.defaultsKey) == legacyHour)
        }
        defaults.set(0, forKey: TranscriptReadingBoundary.defaultsKey)
        #expect(TranscriptReadingBoundary.resolvedHour(from: defaults) == 0)
        #expect(defaults.integer(forKey: DayStartBoundary.defaultsKey) == 23)
    }

    @Test func firstReadBranchesAndExactBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28_800)!
        let early = try #require(ISO8601DateFormatter().date(from: "2026-11-15T23:59:59Z"))
        #expect(TranscriptReadingBoundary.isEarly(early, offset: 28_800, hour: 8))
        #expect(!TranscriptReadingBoundary.isEarly(early.addingTimeInterval(1), offset: 28_800, hour: 8))
        #expect(!TranscriptReadingBoundary.isEarly(early, offset: 28_800, hour: 0))
        #expect(TranscriptReadingBoundary.initiallyExpanded(hasDaytime: true, isToday: true, now: early, calendar: calendar, hour: 8))
        #expect(!TranscriptReadingBoundary.initiallyExpanded(hasDaytime: true, isToday: true, now: early.addingTimeInterval(1), calendar: calendar, hour: 8))
        #expect(TranscriptReadingBoundary.initiallyExpanded(hasDaytime: false, isToday: false, hour: 8))
        #expect(!TranscriptReadingBoundary.initiallyExpanded(hasDaytime: true, isToday: false, hour: 8))
        #expect(TranscriptReadingBoundary.initiallyExpanded(hasDaytime: true, isToday: false, hour: 0))
    }
}
