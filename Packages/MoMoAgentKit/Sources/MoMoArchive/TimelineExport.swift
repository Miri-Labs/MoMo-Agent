import Foundation
import MoMoContracts

public enum TimelineExportScope: Sendable {
    /// Uses the recording-local calendar date, matching the timeline.
    case day(TimelineDay)
    /// Half-open interval; select whole paragraphs by their start time.
    case interval(DateInterval)
}

extension ArchiveStore {
    public func prepareTimelineExport(scope: TimelineExportScope, configurationFingerprint: String? = nil) async throws -> ArchiveExport {
        try Task.checkCancellation()
        let days: [TimelineDay]
        let title: String
        let filename: String
        let interval: DateInterval?
        let date = Self.exportDateFormatter("yyyy-MM-dd", offset: 0)
        switch scope {
        case .day(let day):
            days = [day]
            title = date.string(from: day.date(calendar: TimelineDay.calendar))
            filename = title + ".md"
            interval = nil
        case .interval(let range):
            guard range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
                  range.duration > 0 else { throw ArchiveError.invalidQuery }
            // Recording-local dates can differ from UTC by one day during travel.
            let first = TimelineDay(range.start.addingTimeInterval(-86_400), calendar: TimelineDay.calendar)
            let last = TimelineDay(range.end.addingTimeInterval(86_400), calendar: TimelineDay.calendar)
            days = try insightTimelineCatalog().days.filter { first <= $0 && $0 <= last }.sorted()
            let display = Self.exportDateFormatter("yyyy-MM-dd HH:mm ZZZZZ")
            let file = Self.exportDateFormatter("yyyy-MM-dd_HH-mm")
            title = "\(display.string(from: range.start)) – \(display.string(from: range.end))"
            filename = "\(file.string(from: range.start))_\(file.string(from: range.end)).md"
            interval = range
        }
        var entries: [(date: Date, key: String, heading: String, text: String)] = []
        var references: [SourceReference] = []
        var generations: [UUID: Int64] = [:]
        var seen = Set<String>()
        func contains(_ date: Date) -> Bool {
            guard let interval else { return true }
            return interval.start <= date && date < interval.end
        }
        for day in days {
            try Task.checkCancellation()
            for window in try timelineDay(day, configurationFingerprint: configurationFingerprint) {
                try Task.checkCancellation()
                let stamp = Self.exportDateFormatter("yyyy-MM-dd HH:mm:ss ZZZZZ", offset: window.id.timezoneOffset)
                for paragraph in window.paragraphs where paragraph.hasReadableText && contains(paragraph.recordedAt) {
                    let key = "\(paragraph.source.sessionID)/\(paragraph.id)"
                    guard seen.insert(key).inserted else { continue }
                    references.append(paragraph.source)
                    generations[paragraph.source.sessionID] = paragraph.source.generation
                    entries.append((paragraph.recordedAt, key, stamp.string(from: paragraph.recordedAt),
                                    Self.exportMarkdownText(paragraph.speaker.map { "[\($0)] \(paragraph.text)" } ?? paragraph.text)))
                }
                for mark in window.marks where contains(mark.recordedAt) {
                    let key = "mark/\(mark.id)"
                    guard seen.insert(key).inserted else { continue }
                    generations[mark.sessionID] = mark.generation
                    entries.append((mark.recordedAt, key, stamp.string(from: mark.recordedAt),
                                    "⚑ " + String(localized: "标记", bundle: AppLanguage.resourceBundle)))
                }
            }
            // Long ranges yield between dates so receiving and transcription can keep using the archive.
            await Task.yield()
        }
        guard !references.isEmpty else { throw ArchiveExportError.noTranscriptInRange }
        let createdAt = Date()
        let id = UUID(), directory = exportRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(filename)
        let artifact = ArchiveExport(id: id, fileURLs: [url], createdAt: createdAt, directory: directory,
                                     source: .timeline(references: references, generations: generations))
        let note = String(localized: "仅包含分享时已有的文字；按段落起始时间选取，保留完整段落。", bundle: AppLanguage.resourceBundle)
        let exportedAt = Self.exportDateFormatter("yyyy-MM-dd HH:mm:ss ZZZZZ").string(from: createdAt)
        var markdown = "# \(title)\n\n> \(note)\n>\n> \(exportedAt)\n\n"
        for entry in entries.sorted(by: { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }) {
            markdown += "## \(entry.heading)\n\n\(entry.text)\n\n"
        }
        try validateExportTemporaryPath(directory)
        do {
            try Task.checkCancellation()
            try ArchiveFilePolicy.prepareDirectory(directory)
            try ArchiveFilePolicy.write(Data(markdown.utf8), to: url)
            try Task.checkCancellation()
            try validateExportSource(artifact)
            return artifact
        } catch {
            try removeExport(artifact)
            throw error
        }
    }

    private static func exportDateFormatter(_ format: String, offset: Int? = nil) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        value.dateFormat = format
        return value
    }

    /// Preserve transcript text without turning dictated Markdown or HTML into active formatting.
    private static func exportMarkdownText(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "#", "+", "-", ".", "!", "|"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return escaped
    }
}
