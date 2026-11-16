import Foundation

/// A reading preference only. Zero means show all; recording dates are always natural days.
public enum TranscriptReadingBoundary {
    public static let defaultsKey = "timeline.earlyTranscriptHour"
    public static let defaultHour = 8
    public static let hourRange = 0...23

    public static func resolvedHour(from defaults: UserDefaults = .standard) -> Int {
        guard let number = defaults.object(forKey: defaultsKey) as? NSNumber,
              hourRange.contains(number.intValue) else { return defaultHour }
        return number.intValue
    }

    public static func label(for hour: Int) -> String {
        hour == 0 ? String(localized: "全部展开") : String(format: "%02d:00", hour)
    }

    public static func isEarly(_ date: Date, offset: Int, hour: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        return hour > 0 && calendar.component(.hour, from: date) < hour
    }

    public static func initiallyExpanded(hasDaytime: Bool, isToday: Bool, now: Date = .now,
                                         calendar: Calendar = .current, hour: Int) -> Bool {
        hour == 0 || !hasDaytime || (isToday && calendar.component(.hour, from: now) < hour)
    }
}
