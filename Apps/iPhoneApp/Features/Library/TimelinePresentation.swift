import SwiftUI
import MoMoArchive
import MoMoContracts

enum TimelineDateRange: Equatable {
    case unknown, empty
    case known(ClosedRange<TimelineDay>)

    init(earliestDay: TimelineDay?, hasLoaded: Bool, latestDay: TimelineDay? = nil, today: TimelineDay = TimelineDay(Date())) {
        if !hasLoaded { self = .unknown }
        else if let earliestDay { self = .known(min(earliestDay, today)...max(today, latestDay ?? today)) }
        else { self = .empty }
    }

    var isUnknown: Bool { if case .unknown = self { true } else { false } }

    func canRequest(_ day: TimelineDay, today: TimelineDay = TimelineDay(Date())) -> Bool {
        switch self {
        case .unknown: return day <= today // Wait for the real lower bound before admitting navigation.
        case .empty: return day == today
        case .known(let bounds): return bounds.contains(day)
        }
    }
}

@MainActor
enum TimelineDate {
    private struct Clock: Hashable { let offset: Int; let seconds: Bool }
    private static var clocks: [Clock: DateFormatter] = [:]
    static func day(_ day: TimelineDay) -> String {
        let today = TimelineDay(Date())
        let prefix = day == today ? String(localized: "今天 · ") : day == today.adding(days: -1) ? String(localized: "昨天 · ") : ""
        let date = day.date()
        let style = Date.FormatStyle.dateTime.locale(AppLanguage.current.locale).month().day()
        let formatted = day.year == today.year ? date.formatted(style) : date.formatted(style.year())
        return prefix + formatted
    }
    static func time(_ date: Date, offset: Int, seconds: Bool = false) -> String {
        let key = Clock(offset: offset, seconds: seconds)
        let formatter: DateFormatter
        if let cached = clocks[key] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            formatter.timeZone = TimeZone(secondsFromGMT: offset)
            formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
            if clocks.count >= 32 { clocks.removeAll(keepingCapacity: true) }
            clocks[key] = formatter
        }
        return formatter.string(from: date)
    }
    static func range(_ id: TimelineWindowID, end: Date, includeUTCOffset: Bool = true) -> String {
        let first = time(id.start, offset: id.timezoneOffset)
        let last = time(end, offset: id.timezoneOffset)
        let clock = first == last ? first : "\(first)–\(last)"
        return includeUTCOffset ? "\(clock) · \(utcOffset(id.timezoneOffset))" : clock
    }
    nonisolated static func repeatedClockRanges(in windows: [TimelineWindow]) -> Set<TimelineWindowID> {
        // The archive stores capture offsets, not zone identifiers. Compare recorded wall
        // minutes instead of guessing a historical zone from the phone's current settings.
        guard Set(windows.map(\.id.timezoneOffset)).count > 1 else { return [] }
        let local = windows.map { window in
            (id: window.id,
             first: floor((window.id.start.timeIntervalSince1970 + Double(window.id.timezoneOffset)) / 60),
             last: floor((window.end.timeIntervalSince1970 + Double(window.id.timezoneOffset)) / 60))
        }.sorted { $0.first < $1.first }
        var repeated: Set<TimelineWindowID> = []
        // Forward: an earlier interval reaches this start. Backward: a later start
        // lies within this interval. Two maxima suffice to exclude the current offset.
        for backward in [false, true] {
            var maxima: [(offset: Int, value: Double)] = []
            for index in local.indices {
                let value = local[backward ? local.count - 1 - index : index]
                let threshold = backward ? -value.last : value.first
                if let other = maxima.first(where: { $0.offset != value.id.timezoneOffset }), other.value >= threshold {
                    repeated.insert(value.id)
                }
                let candidate = backward ? -value.first : value.last
                if let existing = maxima.firstIndex(where: { $0.offset == value.id.timezoneOffset }) {
                    maxima[existing].value = max(maxima[existing].value, candidate)
                } else {
                    maxima.append((value.id.timezoneOffset, candidate))
                }
                maxima.sort { $0.value > $1.value }
                if maxima.count > 2 { maxima.removeLast() }
            }
        }
        return repeated
    }
    private static func utcOffset(_ offset: Int) -> String {
        let magnitude = abs(offset)
        let result = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", magnitude / 3_600, magnitude % 3_600 / 60)
        return magnitude % 60 == 0 ? result : result + String(format: ":%02d", magnitude % 60)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "\(max(1, Int(seconds.rounded()))) 秒") }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return String(localized: "\(totalMinutes) 分钟") }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 { return String(localized: "\(hours) 小时") }
        return String(localized: "\(hours) 小时 \(minutes) 分钟")
    }

    static func liveDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(1, Int(seconds.rounded(.up)))
        if totalSeconds < 60 {
            return String(localized: "\(totalSeconds) 秒")
        }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(localized: "\(hours) 小时 \(minutes) 分 \(String(format: "%02d", secs)) 秒")
        }
        return String(localized: "\(minutes) 分 \(String(format: "%02d", secs)) 秒")
    }
}

@MainActor
enum TimelinePresentation {
    static func activity(_ intervals: [DateInterval], from start: Date, to end: Date, count: Int) -> [Double] {
        let duration = end.timeIntervalSince(start)
        guard count > 0, duration.isFinite, duration > 0 else { return [] }
        let step = duration / Double(count)
        var edges = [Double](repeating: 0, count: count)
        var fullBins = [Double](repeating: 0, count: count + 1)
        for interval in intervals {
            let lower = max(0, min(duration, interval.start.timeIntervalSince(start))) / step
            let upper = max(0, min(duration, interval.end.timeIntervalSince(start))) / step
            guard upper > lower else { continue }
            let first = min(count - 1, Int(lower)), last = min(count - 1, Int(upper))
            if first == last { edges[first] += upper - lower }
            else {
                edges[first] += Double(first + 1) - lower
                edges[last] += upper - Double(last)
                fullBins[first + 1] += 1
                fullBins[last] -= 1
            }
        }
        var full = 0.0
        return edges.indices.map { index in
            full += fullBins[index]
            return min(1, max(0, edges[index] + full))
        }
    }

    static func resourceExplanation(_ snapshot: TranscriptionSnapshot?) -> String? {
        guard snapshot?.nativeInFlight != true else { return nil }
        switch snapshot?.historicalResourceConstraint {
        case .thermalPressure: return String(localized: "手机温度过高，历史录音将在降温后自动继续整理")
        case .lowPower: return String(localized: "低电量模式已开启，历史录音将在关闭后自动继续整理")
        case nil: return nil
        }
    }

    static func preview(_ window: TimelineWindow, summary: String?) -> String {
        if window.canSummarize, let summary {
            let preview = MarkdownDocument.plainTextPreview(summary)
            if !preview.isEmpty { return preview }
        }
        var text = ""
        for paragraph in window.paragraphs where paragraph.hasReadableText {
            if !text.isEmpty { text += "  " }
            text += paragraph.text.prefix(max(0, 256 - text.count))
            if text.count >= 256 { break }
        }
        if !text.isEmpty { return String(text.prefix(256)).replacingOccurrences(of: "\n", with: " ") }
        switch window.state {
        case .waitingForTranscription: return ""
        case .waitingForSync: return String(localized: "等待原音传到手机后自动整理。")
        case .failed: return String(localized: "暂未生成文字，原音仍保留。")
        case .complete:
            return window.speechDuration > 0 ? String(localized: "这段有语音，可回听原音。") : String(localized: "未识别到语音")
        }
    }

    private enum PreparationStatus {
        case partialFailure, failed, waitingForSync, processing, deferred, pending
        var title: String {
            switch self {
            case .partialFailure: String(localized: "部分未完成")
            case .failed: String(localized: "未能整理")
            case .waitingForSync: String(localized: "等待同步")
            case .processing: String(localized: "正在整理")
            case .deferred: String(localized: "稍后继续")
            case .pending: String(localized: "等待整理")
            }
        }
    }
    static func status(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> String? {
        statusKind(window, transcription: transcription, speechFailure: speechFailure)?.title
    }
    static func hasRetryableFailure(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> Bool {
        switch statusKind(window, transcription: transcription, speechFailure: speechFailure) {
        case .partialFailure, .failed: true
        default: false
        }
    }
    private static func statusKind(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> PreparationStatus? {
        switch window.state {
        case .failed: return window.paragraphs.contains(where: \.hasReadableText) ? .partialFailure : .failed
        case .waitingForSync: return .waitingForSync
        case .complete: return nil
        case .waitingForTranscription:
            // A pending window can span several recordings. Durable completion/sync/failure
            // above takes precedence; only matching, in-flight native work is active.
            let sources = window.sources.map {
                RecordingTranscriptionPresentation(sessionID: $0.sessionID, state: .pending, snapshot: transcription)
            }
            if sources.contains(where: { $0.activity == .failed }) { return .partialFailure }
            if sources.contains(where: \.isActive) { return .processing }
            if sources.contains(where: { $0.activity == .deferred }) { return .deferred }
            return speechFailure == nil ? .pending : .failed
        }
    }
    static func explanation(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> String? {
        switch statusKind(window, transcription: transcription, speechFailure: speechFailure) {
        case .waitingForSync: String(localized: "还有原音尚未传到手机，已收到的文字和原音可以先查看。")
        case .processing: String(localized: "正在整理，后续文字会自动补上。")
        case .pending: String(localized: "原音已收到，文字将自动整理。")
        case .deferred: String(localized: "回到 App 或系统允许后会继续整理，已有内容已保留。")
        case .partialFailure, .failed: String(localized: "部分文字未能生成，已有文字和原音会保留。")
        default: nil
        }
    }
}

struct TimelineRow: View {
    let window: TimelineWindow
    let summary: String?
    let status: String?
    let connected: Bool
    var continuesFromPrevious = false
    var includeUTCOffset = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var excerptSize: CGFloat = 16

    private var recap: TranscriptRecapContent? {
        guard window.canSummarize, let summary else { return nil }
        let parsed = TranscriptRecapContent.parse(summary)
        return parsed.isEmpty ? nil : parsed
    }

    private var hasReadableText: Bool {
        window.paragraphs.contains(where: \.hasReadableText)
    }

    var body: some View {
        let timeText = TimelineDate.range(window.id, end: window.end, includeUTCOffset: includeUTCOffset)
        let parsedRecap = recap
        let hasSummary = parsedRecap != nil

        VStack(alignment: .leading, spacing: 14) {
            metadataRow(timeText: timeText, hasSummary: hasSummary)

            if let parsedRecap {
                TranscriptRecapBody(content: parsedRecap, compact: true)
                    .equatable()
            } else {
                let preview = TimelinePresentation.preview(window, summary: nil)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: excerptSize, weight: .regular))
                        .lineSpacing(5)
                        .foregroundStyle(hasReadableText ? MoMoPalette.ink.opacity(0.90) : MoMoPalette.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, window.marks.isEmpty ? 24 : 18)
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func metadataRow(timeText: String, hasSummary: Bool) -> some View {
        let durationText: String? = (window.speechDuration > 0 && window.state == .complete)
            ? TimelineDate.duration(window.speechDuration)
            : nil

        HStack(alignment: .center, spacing: 6) {
            Image(systemName: hasSummary ? "text.page" : "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MoMoPalette.muted.opacity(0.85))
                .accessibilityHidden(true)

            HStack(spacing: 5) {
                Text(timeText)
                    .phoneText(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
                    .lineLimit(1)

                if let durationText {
                    Text("·")
                        .phoneText(.metadata)
                        .foregroundStyle(MoMoPalette.muted.opacity(0.6))
                        .accessibilityHidden(true)
                    Text(durationText)
                        .phoneText(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(1)
                        .accessibilityIdentifier("timeline.speechDuration")
                }

                if !hasSummary, hasReadableText, status == nil {
                    Text("·")
                        .phoneText(.metadata)
                        .foregroundStyle(MoMoPalette.muted.opacity(0.6))
                        .accessibilityHidden(true)
                    Text("原文")
                        .phoneText(.metadata)
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailingAccessory(hasSummary: hasSummary)
        }
    }

    @ViewBuilder
    private func trailingAccessory(hasSummary: Bool) -> some View {
        if let status {
            HStack(spacing: 5) {
                if status == String(localized: "正在整理") {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .phoneText(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(MoMoPalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(MoMoPalette.ink.opacity(0.05), in: Capsule())
        } else {
            HStack(spacing: 8) {
                if !window.isFinal {
                    Circle()
                        .fill(MoMoPalette.ink)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Image(systemName: hasSummary ? "waveform" : "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(MoMoPalette.ink.opacity(0.045), in: Circle())
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
enum RecordingDatePresentation {
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let target = TimelineDay(date, calendar: calendar)
        let today = TimelineDay(now, calendar: calendar)
        if target == today { return String(localized: "今天") }
        if target == today.adding(days: -1) { return String(localized: "昨天") }
        return target.date(calendar: calendar).formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day())
    }

    static func title(_ date: Date, offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
        let target = TimelineDay(date, calendar: calendar)
        return "\(TimelineDate.day(target)) \(TimelineDate.time(date, offset: offset))"
    }

    static func title(_ date: Date) -> String {
        "\(day(date)) \(date.formatted(.dateTime.hour().minute()))"
    }
}
