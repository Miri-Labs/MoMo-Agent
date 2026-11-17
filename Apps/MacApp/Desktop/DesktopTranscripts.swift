import AppKit
import SwiftUI
import MoMoAgentClient
import MoMoContracts

extension ContextSourceWindow {
    func displayTimeZone(fallback: TimeZone = .current) -> TimeZone {
        guard dateEvidence != "timezone_unknown", let timezoneOffset,
              let zone = TimeZone(secondsFromGMT: timezoneOffset) else { return fallback }
        return zone
    }
}

struct DesktopTranscriptWindow: Identifiable, Equatable, Sendable {
    let source: ContextSource
    let window: ContextSourceWindow
    let logicalDayKey: String
    let displayPreview: String
    let searchText: String
    let rangeTimeLabel: String
    let datedTimeLabel: String
    var id: String { window.id }
    var recordedAt: Double? { window.recordedAt ?? source.recordedAt }
    var endAt: Double? { window.endAt ?? recordedAt }
    var summary: String? { window.summary }
    var preview: String? { window.preview ?? source.preview }
}

struct DesktopTranscriptSnapshot: Equatable, Sendable {
    let version: UInt64
    let ordered: [DesktopTranscriptWindow]
    let windowsByDayKey: [String: [DesktopTranscriptWindow]]
    let windowByID: [String: DesktopTranscriptWindow]
    let sourceByIDRevision: [String: ContextSource]
    let earliestLogicalDay: Date?
    let latestRecordedAt: Double?

    static let empty = DesktopTranscriptSnapshot(
        version: 0,
        ordered: [],
        windowsByDayKey: [:],
        windowByID: [:],
        sourceByIDRevision: [:],
        earliestLogicalDay: nil,
        latestRecordedAt: nil
    )

    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private nonisolated static let clockFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    nonisolated static func build(sources: [ContextSource], dayStartHour: Int, version: UInt64, calendar: Calendar = .current) -> DesktopTranscriptSnapshot {
        guard !sources.isEmpty else {
            return DesktopTranscriptSnapshot(
                version: version,
                ordered: [],
                windowsByDayKey: [:],
                windowByID: [:],
                sourceByIDRevision: [:],
                earliestLogicalDay: nil,
                latestRecordedAt: nil
            )
        }
        let locale = AppLanguage.current.locale

        var sourceByIDRevision: [String: ContextSource] = [:]
        sourceByIDRevision.reserveCapacity(sources.count)

        var rawItems: [(source: ContextSource, window: ContextSourceWindow)] = []
        rawItems.reserveCapacity(sources.count * 2)

        for source in sources {
            sourceByIDRevision["\(source.id)|\(source.revision)"] = source
            if let windows = source.windows, !windows.isEmpty {
                for w in windows {
                    rawItems.append((source, w))
                }
            } else {
                let fallback = ContextSourceWindow(
                    id: source.id,
                    sourceId: source.id,
                    sourceRevision: source.revision,
                    recordedAt: source.recordedAt,
                    endAt: source.recordedAt,
                    offset: 0,
                    end: source.totalCharacters,
                    totalCharacters: source.totalCharacters,
                    summary: source.summary,
                    preview: source.preview
                )
                rawItems.append((source, fallback))
            }
        }

        rawItems.sort { ($0.window.recordedAt ?? $0.source.recordedAt ?? 0) < ($1.window.recordedAt ?? $1.source.recordedAt ?? 0) }

        var ordered: [DesktopTranscriptWindow] = []
        ordered.reserveCapacity(rawItems.count)
        var windowsByDayKey: [String: [DesktopTranscriptWindow]] = [:]
        var windowByID: [String: DesktopTranscriptWindow] = [:]
        windowByID.reserveCapacity(rawItems.count)
        var earliestDay: Date?

        let unknownLabel = String(localized: "时间不详")

        for pair in rawItems {
            let timestamp = pair.window.recordedAt ?? pair.source.recordedAt
            let endTimestamp = pair.window.endAt ?? timestamp
            let dayKeyValue: String
            let rangeLabel: String
            let datedLabel: String

            if let ts = timestamp {
                let startDate = Date(timeIntervalSince1970: ts)
                let endDate = Date(timeIntervalSince1970: endTimestamp ?? ts)
                var sourceCalendar = Calendar(identifier: .gregorian)
                sourceCalendar.timeZone = pair.window.displayTimeZone(fallback: calendar.timeZone)
                let naturalKey = Self.dayKey(for: startDate, calendar: sourceCalendar)
                let components = naturalKey.split(separator: "-").compactMap { Int($0) }
                let logicalStart = components.count == 3
                    ? calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])) ?? calendar.startOfDay(for: startDate)
                    : calendar.startOfDay(for: startDate)
                if let currentEarliest = earliestDay {
                    if logicalStart < currentEarliest { earliestDay = logicalStart }
                } else {
                    earliestDay = logicalStart
                }
                dayKeyValue = naturalKey
                var clock = Self.clockFormat
                clock.timeZone = sourceCalendar.timeZone
                let sText = startDate.formatted(clock)
                let eText = endDate.formatted(clock)
                let rText = sText == eText ? sText : "\(sText)–\(eText)"
                rangeLabel = rText
                let dayPrefix = logicalStart.formatted(.dateTime.locale(locale).month().day())
                datedLabel = "\(dayPrefix) \(rText)"
            } else {
                dayKeyValue = ""
                rangeLabel = unknownLabel
                datedLabel = unknownLabel
            }

            let rawSummary = pair.window.summary
            let rawPreview = pair.window.preview ?? pair.source.preview
            let previewText = rawSummary.map { MarkdownDocument.plainTextPreview($0) } ?? rawPreview ?? ""
            let searchable = (rawSummary ?? rawPreview ?? "").lowercased()

            let item = DesktopTranscriptWindow(
                source: pair.source,
                window: pair.window,
                logicalDayKey: dayKeyValue,
                displayPreview: previewText,
                searchText: searchable,
                rangeTimeLabel: rangeLabel,
                datedTimeLabel: datedLabel
            )
            ordered.append(item)
            windowByID[item.id] = item
            if !dayKeyValue.isEmpty {
                windowsByDayKey[dayKeyValue, default: []].append(item)
            }
        }

        return DesktopTranscriptSnapshot(
            version: version,
            ordered: ordered,
            windowsByDayKey: windowsByDayKey,
            windowByID: windowByID,
            sourceByIDRevision: sourceByIDRevision,
            earliestLogicalDay: earliestDay,
            latestRecordedAt: ordered.last?.recordedAt
        )
    }
}

struct DesktopSources: View {
    @Bindable var model: DesktopModel
    var isActive: Bool = true
    var resetToken: UInt64 = 0
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var selectedID: String?
    @State private var query = ""
    @State private var searching = false
    @State private var choosingDate = false
    @State private var selectedIllustrationID: String?
    @State private var illustrationError: String?
    @State private var expandedDays: [String: Bool] = [:]
    @State private var selectedSpanID: String?
    private let calendar = Calendar.current
    private let defaultLocalOffset = TimeZone.current.secondsFromGMT()

    private var selectedDayKey: String { DesktopTranscriptSnapshot.dayKey(for: day, calendar: calendar) }

    /// Fast integer hour check without per-row TimeZone/Calendar allocations on the main thread.
    private func isEarly(_ item: DesktopTranscriptWindow) -> Bool {
        let limitHour = model.dayStartHour
        guard limitHour > 0, let timestamp = item.recordedAt else { return false }
        let offset = (item.window.dateEvidence != "timezone_unknown" ? item.window.timezoneOffset : nil) ?? defaultLocalOffset
        let localSec = Int(floor(timestamp)) + offset
        let secOfDay = ((localSec % 86_400) + 86_400) % 86_400
        return (secOfDay / 3600) < limitHour
    }

    private func logicalDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private var logicalToday: Date {
        logicalDay(for: Date())
    }

    private var snapshot: DesktopTranscriptSnapshot {
        model.transcriptSnapshot
    }

    private var visible: [DesktopTranscriptWindow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return snapshot.ordered.filter { $0.searchText.contains(trimmed) }
        }
        let key = DesktopTranscriptSnapshot.dayKey(for: day, calendar: calendar)
        return snapshot.windowsByDayKey[key] ?? []
    }

    private var selected: DesktopTranscriptWindow? {
        guard let selectedID else { return nil }
        return snapshot.windowByID[selectedID]
    }

    private var illustrations: [LifeIllustration] {
        model.lifeIllustrations.readyItems
    }

    private var selectedIllustration: LifeIllustration? {
        guard let selectedIllustrationID else { return nil }
        return illustrations.first { $0.id == selectedIllustrationID }
    }

    private var dayIllustrations: [LifeIllustration] {
        model.lifeIllustrations.readyItems(forDay: selectedDayKey)
    }

    private func overlaps(_ window: DesktopTranscriptWindow, illustration: LifeIllustration) -> Bool {
        guard let start = window.recordedAt else { return false }
        let end = window.endAt ?? start
        return start < illustration.windowEnd && (end > illustration.windowStart || start >= illustration.windowStart)
    }

    private var earliest: Date {
        min(
            snapshot.earliestLogicalDay ?? calendar.startOfDay(for: day),
            logicalToday
        )
    }

    private var latestSelectableDay: Date {
        let key = snapshot.windowsByDayKey.keys.max() ?? ""
        let parts = key.split(separator: "-").compactMap { Int($0) }
        let latest = parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        return max(logicalToday, latest ?? logicalToday)
    }

    var body: some View {
        Group {
            if let illustration = selectedIllustration {
                Group {
                    if dayIllustrations.contains(where: { $0.coordinate != nil }) {
                        LifeIllustrationJourneyMapView(
                            store: model.lifeIllustrations,
                            initialID: illustration.id,
                            referenceDay: selectedDayKey,
                            close: closeIllustration,
                            showSource: { showSource(for: $0) }
                        )
                    } else {
                        LifeIllustrationViewer(
                            store: model.lifeIllustrations,
                            initialID: illustration.id,
                            referenceDay: selectedDayKey,
                            close: closeIllustration,
                            showSource: { showSource(for: $0) }
                        )
                    }
                }
                .id(selectedDayKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected {
                DesktopSourceReader(
                    model: model,
                    source: selected.source,
                    window: selected.window,
                    initialSpanID: selectedSpanID,
                    close: { selectedID = nil }
                )
                .id(selected.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(MoMoPalette.pane)
        .onChange(of: resetToken) {
            if selectedIllustrationID != nil {
                selectedIllustrationID = nil
            } else if selectedID != nil {
                selectedID = nil
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.loadContextIfStale(maxAge: 10)
        }
        .onChange(of: model.dayStartHour) {
            expandedDays.removeAll()
            expandedDays[selectedDayKey] = TranscriptReadingBoundary.initiallyExpanded(
                hasDaytime: visible.contains { !isEarly($0) }, isToday: calendar.isDate(day, inSameDayAs: logicalToday),
                hour: model.dayStartHour)
        }
        .onChange(of: snapshot.version) {
            if selectedID != nil && selected == nil { selectedID = nil }
        }
        .onChange(of: model.lifeIllustrations.readyItems) {
            if selectedIllustrationID != nil && selectedIllustration == nil { closeIllustration() }
        }
        .alert("生活插画", isPresented: Binding(
            get: { illustrationError != nil },
            set: { if !$0 { illustrationError = nil } }
        )) {
            Button("好", role: .cancel) { illustrationError = nil }
        } message: {
            Text(illustrationError ?? "")
        }
    }

    private func buildTimelineEntries(
        currentVisible: [DesktopTranscriptWindow],
        early: [DesktopTranscriptWindow],
        daytime: [DesktopTranscriptWindow],
        expanded: Bool
    ) -> [MacTranscriptListEntry] {
        var entries: [MacTranscriptListEntry] = []
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isSearching && !early.isEmpty {
            entries.append(.earlyHeader(
                count: early.count,
                rangeText: "00:00–" + TranscriptReadingBoundary.label(for: model.dayStartHour),
                isExpanded: expanded
            ))
        }
        let windows = isSearching || expanded ? currentVisible : daytime
        entries.reserveCapacity(entries.count + windows.count)
        for item in windows {
            let (headline, bodyText) = MacTranscriptListEntry.splitDigest(item.displayPreview)
            entries.append(.window(
                item: item,
                timeLabel: isSearching ? item.datedTimeLabel : item.rangeTimeLabel,
                headline: headline,
                excerpt: bodyText
            ))
        }
        return entries
    }

    private var timeline: some View {
        let currentVisible = visible
        let early = currentVisible.filter(isEarly)
        let daytime = currentVisible.filter { !isEarly($0) }
        let hasDaytime = !daytime.isEmpty
        let expanded = expandedDays[selectedDayKey] ?? TranscriptReadingBoundary.initiallyExpanded(
            hasDaytime: hasDaytime,
            isToday: calendar.isDate(day, inSameDayAs: logicalToday),
            hour: model.dayStartHour
        )
        let entries = buildTimelineEntries(
            currentVisible: currentVisible,
            early: early,
            daytime: daytime,
            expanded: expanded
        )
        let currentDayIllustrations = (!searching && query.isEmpty) ? dayIllustrations : []

        return VStack(spacing: 0) {
            // Grok Bot (`sand`) unified 44pt stage header bar
            ZStack {
                DesktopWindowDragRegion()
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Text("转录")
                            .font(.system(size: 14, weight: .medium))
                            .tracking(-0.1)
                            .foregroundStyle(MoMoPalette.ink)
                            .accessibilityAddTraits(.isHeader)
                        if !currentVisible.isEmpty {
                            Text("\(currentVisible.count)")
                                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                                .foregroundStyle(MoMoPalette.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(MoMoPalette.ink.opacity(0.055), in: Capsule())
                        }
                    }

                    Spacer(minLength: 12)

                    if searching {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MoMoPalette.muted)
                            TextField("搜索全部摘要与片段…", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .frame(width: 190)
                                .accessibilityIdentifier("desktop.transcripts.search")
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(MoMoPalette.muted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .momoElevatedCard(cornerRadius: 999, isFocused: true, shadowStrength: 0.45)
                    }

                    dateBar

                    TranscriptIconActionButton(
                        symbol: "arrow.clockwise",
                        isActive: false,
                        disabled: model.contextLoading,
                        helpText: "刷新转录",
                        accessibilityLabel: "刷新",
                        accessibilityID: "desktop.transcripts.refresh"
                    ) {
                        Task { await model.loadContext() }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MoMoPalette.borderSubtle)
                    .frame(height: 0.5)
                    .allowsHitTesting(false)
            }

            if let error = model.memoryError {
                HStack(spacing: 8) {
                    Text(error).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
                    Spacer()
                    Button("重试") { Task { await model.loadContext() } }
                        .font(.caption)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: 720)
            }

            if !currentDayIllustrations.isEmpty {
                LifeIllustrationStripView(
                    items: currentDayIllustrations,
                    store: model.lifeIllustrations,
                    horizontalMargin: 24,
                    open: { selectedIllustrationID = $0.id },
                    showSource: { showSource(for: $0) },
                    failure: { illustrationError = $0 }
                )
                .frame(maxWidth: 720)
                .padding(.top, 8)
            }

            if entries.isEmpty || (entries.count == 1 && !hasDaytime && !expanded && query.isEmpty) {
                VStack(spacing: 14) {
                    if let first = entries.first, case let .earlyHeader(count, rangeText, isExp) = first {
                        Button {
                            expandedDays[selectedDayKey] = !isExp
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isExp ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("凌晨记录 · \(count) 段")
                                Spacer()
                                Text(rangeText).monospacedDigit()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MoMoPalette.muted)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .momoElevatedCard(cornerRadius: 10, shadowStrength: 0.35)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 680)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    }

                    Spacer(minLength: 24)
                    if model.contextLoading && currentVisible.isEmpty {
                        ProgressView("正在读取记录")
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(MoMoPalette.tertiaryInk)
                        Text(query.isEmpty
                             ? (!early.isEmpty ? "当天 \(TranscriptReadingBoundary.label(for: model.dayStartHour)) 后暂无记录" : "这一天还没有转录")
                             : "没有匹配的转录")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MoMoPalette.ink)
                        Text(query.isEmpty ? "手机与手腕同步的录音片段会按时间线陈列在这里。" : "试试换个关键词搜索摘要与片段。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoMoPalette.muted)
                        if query.isEmpty, snapshot.latestRecordedAt != nil,
                           snapshot.ordered.last?.logicalDayKey != selectedDayKey {
                            Button("跳转到最近有记录的一天") {
                                if let key = snapshot.ordered.last?.logicalDayKey { selectSourceDay(key) }
                            }
                            .buttonStyle(MoMoPressableButtonStyle(scale: 0.97))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MoMoPalette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .momoElevatedCard(cornerRadius: 999, shadowStrength: 0.55)
                            .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Native AppKit 120fps NSTableView timeline: zero SwiftUI scroll state feedback, instant 500+ row search.
                MacTranscriptTimelineListView(
                    entries: entries,
                    onToggleEarly: {
                        expandedDays[selectedDayKey] = !expanded
                    },
                    onSelectWindow: { item in
                        closeIllustration()
                        selectedSpanID = nil
                        if !query.isEmpty {
                            selectSourceDay(item.logicalDayKey)
                            expandedDays[item.logicalDayKey] = true
                        }
                        selectedID = item.id
                    }
                )
                .momoScrollEdgeFade(top: 10, surface: MoMoPalette.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: currentVisible.isEmpty, initial: true) { _, empty in
            if !empty, expandedDays[selectedDayKey] == nil { expandedDays[selectedDayKey] = expanded }
        }
    }

    private func closeIllustration() {
        selectedIllustrationID = nil
    }

    private func selectSourceDay(_ key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) { day = date }
    }

    private func showSource(for illustration: LifeIllustration) {
        let referenceKey = illustration.belongs(to: selectedDayKey) ? selectedDayKey : illustration.primaryDay
        let anchor = illustration.transcriptAnchor(on: referenceKey)
        let key = anchor?.day ?? referenceKey
        guard let source = snapshot.ordered.first(where: {
            $0.logicalDayKey == key && illustration.sourceIds.contains($0.source.id)
                && overlaps($0, illustration: illustration)
                && (anchor == nil || (($0.recordedAt ?? 0) <= anchor!.recordedAt && ($0.endAt ?? 0) >= anchor!.recordedAt))
        }) else {
            illustrationError = String(localized: "原始转录尚未同步。")
            return
        }
        closeIllustration()
        query = ""; searching = false
        selectSourceDay(key)
        expandedDays[key] = true
        selectedSpanID = anchor?.spanId
        selectedID = source.id
    }

    private var dateBar: some View {
        let canPrev = day > earliest && query.isEmpty
        let canNext = day < latestSelectableDay && query.isEmpty
        return HStack(spacing: 6) {
            HStack(spacing: 1) {
                TranscriptStepButton(symbol: "chevron.left", enabled: canPrev, label: "前一天") {
                    moveDay(-1)
                }

                TranscriptDateLabelButton(
                    title: query.isEmpty ? dayTitle(day) : String(localized: "全部日期"),
                    action: { choosingDate = true }
                )
                .popover(isPresented: $choosingDate) {
                    VStack(spacing: 14) {
                        DatePicker("选择日期", selection: $day, in: earliest...latestSelectableDay, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        HStack {
                            Button("今天") { day = logicalToday; query = ""; choosingDate = false }
                            Spacer()
                            Button("完成") { query = ""; choosingDate = false }
                        }
                    }
                    .padding(20)
                    .frame(width: 300)
                }

                TranscriptStepButton(symbol: "chevron.right", enabled: canNext, label: "后一天") {
                    moveDay(1)
                }
            }
            .padding(2)
            .momoElevatedCard(cornerRadius: 999, shadowStrength: 0.45)

            TranscriptIconActionButton(
                symbol: searching ? "xmark" : "magnifyingglass",
                isActive: searching,
                disabled: false,
                helpText: searching ? "关闭搜索" : "搜索转录",
                accessibilityLabel: searching ? "关闭搜索" : "搜索转录",
                accessibilityID: nil
            ) {
                searching.toggle()
                if !searching { query = "" }
            }
        }
        .foregroundStyle(MoMoPalette.ink)
    }

    private func moveDay(_ value: Int) {
        if let next = calendar.date(byAdding: .day, value: value, to: day) { day = next }
    }

    private func dayTitle(_ date: Date) -> String {
        let monthDay = date.formatted(.dateTime.locale(AppLanguage.current.locale).month().day())
        let today = logicalToday
        if calendar.isDate(date, inSameDayAs: today) { return String(localized: "今天 · \(monthDay)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "昨天 · \(monthDay)")
        }
        if calendar.isDate(date, equalTo: today, toGranularity: .year) { return monthDay }
        return date.formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day())
    }
}

// MARK: - Native AppKit 120fps Grok-Style Transcript Timeline Table

private enum MacTranscriptListEntry: Equatable {
    case earlyHeader(count: Int, rangeText: String, isExpanded: Bool)
    case window(item: DesktopTranscriptWindow, timeLabel: String, headline: String, excerpt: String)

    var id: String {
        switch self {
        case let .earlyHeader(count, _, isExpanded):
            return "early|\(count)|\(isExpanded)"
        case let .window(item, _, _, _):
            return item.id
        }
    }

    static func splitDigest(_ raw: String) -> (headline: String, excerpt: String) {
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return (String(localized: "录音片段"), "")
        }
        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "总结" && $0 != "主要要点" && $0 != "主要内容要点" }
        guard let first = lines.first else {
            return (String(localized: "录音片段"), "")
        }
        // Only split into separate headline + excerpt when the first line is a genuine short topic title
        if lines.count >= 2 && first.count <= 32 {
            let rest = lines.dropFirst().joined(separator: " · ")
            return (first, rest)
        }
        let joined = lines.joined(separator: " ")
        if let punctIdx = joined.firstIndex(where: { "。！？；.!?;".contains($0) }) {
            let prefixLen = joined.distance(from: joined.startIndex, to: punctIdx)
            if prefixLen >= 4 && prefixLen <= 30 {
                let head = String(joined[..<punctIdx])
                let afterStart = joined.index(after: punctIdx)
                let tail = String(joined[afterStart...])
                    .replacingOccurrences(of: "主要内容要点 ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return (head, tail)
            }
        }
        // Long single-sentence digest: never duplicate the prefix! Render cleanly as a 2-line primary preview.
        return ("", joined.replacingOccurrences(of: "主要内容要点 ", with: ""))
    }
}

private final class MacTranscriptNSTableView: NSTableView {
    var onPrimaryClickRow: ((Int) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private(set) var hoveredRow: Int = -1

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateHover(at: pt)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(-1)
    }

    func refreshHoverFromWindowMouse() {
        guard let window else {
            setHoveredRow(-1)
            return
        }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(pt) {
            updateHover(at: pt)
        } else {
            setHoveredRow(-1)
        }
    }

    private func updateHover(at pt: NSPoint) {
        let r = row(at: pt)
        if r >= 0 && r < numberOfRows {
            let rowRect = rect(ofRow: r)
            let maxCardW: CGFloat = min(692, max(240, bounds.width - 40))
            let sideInset = floor((bounds.width - maxCardW) * 0.5)
            let cardBand = NSRect(x: sideInset, y: rowRect.minY, width: maxCardW, height: rowRect.height)
            setHoveredRow(cardBand.contains(pt) ? r : -1)
        } else {
            setHoveredRow(-1)
        }
    }

    private func setHoveredRow(_ next: Int) {
        guard hoveredRow != next else { return }
        let prev = hoveredRow
        hoveredRow = next
        if prev >= 0, prev < numberOfRows,
           let oldCell = view(atColumn: 0, row: prev, makeIfNecessary: false) as? MacTranscriptRowCellView {
            oldCell.setHovered(false)
        }
        if next >= 0, next < numberOfRows,
           let newCell = view(atColumn: 0, row: next, makeIfNecessary: false) as? MacTranscriptRowCellView {
            newCell.setHovered(true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let r = row(at: pt)
        guard r >= 0, r < numberOfRows else {
            super.mouseDown(with: event)
            return
        }
        onPrimaryClickRow?(r)
    }
}

private final class MacTranscriptRowCellView: NSTableCellView {
    private let cardLayerView = NSView()
    private let timeBadgeLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(labelWithString: "")
    private let actionHintLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    private var currentEntry: MacTranscriptListEntry?
    private var isHoveredState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        cardLayerView.wantsLayer = true
        cardLayerView.layer?.cornerRadius = 12
        cardLayerView.layer?.cornerCurve = .continuous
        addSubview(cardLayerView)

        timeBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        timeBadgeLabel.lineBreakMode = .byClipping
        timeBadgeLabel.maximumNumberOfLines = 1
        addSubview(timeBadgeLabel)

        headlineLabel.font = NSFont.systemFont(ofSize: 13.8, weight: .medium)
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.maximumNumberOfLines = 1
        addSubview(headlineLabel)

        excerptLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        excerptLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.maximumNumberOfLines = 2
        excerptLabel.cell?.wraps = true
        excerptLabel.cell?.truncatesLastVisibleLine = true
        addSubview(excerptLabel)

        actionHintLabel.stringValue = String(localized: "查看原文")
        actionHintLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        actionHintLabel.alignment = .right
        addSubview(actionHintLabel)

        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func configure(with entry: MacTranscriptListEntry, hovered: Bool) {
        currentEntry = entry
        isHoveredState = hovered

        switch entry {
        case let .earlyHeader(count, rangeText, isExpanded):
            let symbolName = isExpanded ? "chevron.down" : "chevron.right"
            chevronView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            headlineLabel.stringValue = "凌晨记录 · \(count) 段"
            headlineLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            timeBadgeLabel.stringValue = rangeText
            excerptLabel.isHidden = true
            actionHintLabel.isHidden = true
            setAccessibilityIdentifier("desktop.transcripts.early.toggle")

        case let .window(item, timeLabel, headline, excerpt):
            chevronView.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            timeBadgeLabel.stringValue = timeLabel
            headlineLabel.stringValue = headline
            headlineLabel.isHidden = headline.isEmpty
            headlineLabel.font = NSFont.systemFont(ofSize: 13.8, weight: .medium)
            excerptLabel.stringValue = excerpt
            excerptLabel.font = NSFont.systemFont(ofSize: headline.isEmpty ? 13.5 : 12.5, weight: .regular)
            excerptLabel.isHidden = excerpt.isEmpty
            actionHintLabel.isHidden = false
            setAccessibilityIdentifier("desktop.source.\(item.id)")
        }

        applyColors()
        needsLayout = true
    }

    func setHovered(_ hovered: Bool) {
        guard isHoveredState != hovered else { return }
        isHoveredState = hovered
        applyColors()
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = NSColor(named: "PhoneInk") ?? .labelColor
        let muted = NSColor(named: "PhoneMuted") ?? .secondaryLabelColor

        switch currentEntry {
        case .earlyHeader:
            cardLayerView.layer?.backgroundColor = (isHoveredState
                ? ink.withAlphaComponent(dark ? 0.065 : 0.045)
                : ink.withAlphaComponent(dark ? 0.03 : 0.024)).cgColor
            cardLayerView.layer?.borderWidth = 0.5
            cardLayerView.layer?.borderColor = ink.withAlphaComponent(0.065).cgColor
            headlineLabel.isHidden = false
            headlineLabel.textColor = muted
            timeBadgeLabel.textColor = muted.withAlphaComponent(0.85)
            chevronView.contentTintColor = muted

        case let .window(_, _, headline, _):
            cardLayerView.layer?.backgroundColor = (isHoveredState
                ? ink.withAlphaComponent(dark ? 0.058 : 0.04)
                : NSColor.clear).cgColor
            cardLayerView.layer?.borderWidth = isHoveredState ? 0.5 : 0
            cardLayerView.layer?.borderColor = ink.withAlphaComponent(dark ? 0.10 : 0.08).cgColor
            timeBadgeLabel.textColor = isHoveredState ? ink.withAlphaComponent(0.85) : muted
            headlineLabel.textColor = ink
            excerptLabel.textColor = headline.isEmpty ? ink.withAlphaComponent(0.88) : muted
            actionHintLabel.textColor = ink.withAlphaComponent(0.75)
            actionHintLabel.alphaValue = isHoveredState ? 1.0 : 0.0
            chevronView.contentTintColor = isHoveredState ? ink.withAlphaComponent(0.85) : muted.withAlphaComponent(0.45)

        case .none:
            break
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let maxCardW: CGFloat = min(692, max(240, w - 40))
        let sideInset = floor((w - maxCardW) * 0.5)

        switch currentEntry {
        case .earlyHeader:
            let cardH: CGFloat = 34
            let cardY = floor((h - cardH) * 0.5)
            cardLayerView.frame = NSRect(x: sideInset, y: cardY, width: maxCardW, height: cardH)
            cardLayerView.layer?.cornerRadius = 9
            chevronView.frame = NSRect(x: sideInset + 13, y: floor((h - 12) * 0.5), width: 12, height: 12)
            timeBadgeLabel.sizeToFit()
            let timeW = ceil(timeBadgeLabel.frame.width)
            timeBadgeLabel.frame = NSRect(
                x: sideInset + maxCardW - 14 - timeW,
                y: floor((h - timeBadgeLabel.frame.height) * 0.5),
                width: timeW,
                height: ceil(timeBadgeLabel.frame.height)
            )
            headlineLabel.sizeToFit()
            let headH = ceil(headlineLabel.frame.height)
            headlineLabel.frame = NSRect(
                x: sideInset + 31,
                y: floor((h - headH) * 0.5),
                width: max(60, maxCardW - 56 - timeW),
                height: headH
            )

        case .window, .none:
            cardLayerView.frame = NSRect(x: sideInset, y: 2, width: maxCardW, height: max(20, h - 4))
            cardLayerView.layer?.cornerRadius = 12

            let leftPad = sideInset + 14
            let timeColW: CGFloat = 94
            let contentX = leftPad + timeColW + 12
            let rightActionW: CGFloat = 78
            let contentW = max(100, sideInset + maxCardW - 14 - rightActionW - contentX)

            timeBadgeLabel.sizeToFit()
            let timeH = ceil(timeBadgeLabel.frame.height)

            if headlineLabel.isHidden {
                let measured = excerptLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentW, height: 44)) ?? NSSize(width: contentW, height: 20)
                let exH = min(max(18, h - 20), ceil(measured.height))
                let exY = floor((h - exH) * 0.5)
                excerptLabel.frame = NSRect(x: contentX, y: exY, width: contentW, height: exH)
                timeBadgeLabel.frame = NSRect(x: leftPad, y: exY + max(0, exH - timeH - 1), width: timeColW, height: timeH)
            } else if excerptLabel.isHidden {
                headlineLabel.sizeToFit()
                let headH = ceil(headlineLabel.frame.height)
                let rowMidY = floor((h - headH) * 0.5)
                headlineLabel.frame = NSRect(x: contentX, y: rowMidY, width: contentW, height: headH)
                timeBadgeLabel.frame = NSRect(x: leftPad, y: floor((h - timeH) * 0.5), width: timeColW, height: timeH)
            } else {
                headlineLabel.sizeToFit()
                let headH = ceil(headlineLabel.frame.height)
                let topY = h - 13 - headH
                headlineLabel.frame = NSRect(x: contentX, y: topY, width: contentW, height: headH)
                timeBadgeLabel.frame = NSRect(x: leftPad, y: topY + floor((headH - timeH) * 0.5), width: timeColW, height: timeH)

                let availExcerptH = max(18, topY - 12)
                let measured = excerptLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentW, height: 40)) ?? NSSize(width: contentW, height: 18)
                let exH = min(availExcerptH, ceil(measured.height))
                excerptLabel.frame = NSRect(x: contentX, y: topY - 4 - exH, width: contentW, height: exH)
            }

            let chevY = floor((h - 13) * 0.5)
            chevronView.frame = NSRect(x: sideInset + maxCardW - 27, y: chevY, width: 13, height: 13)
            actionHintLabel.sizeToFit()
            let hintW = ceil(actionHintLabel.frame.width)
            let hintH = ceil(actionHintLabel.frame.height)
            actionHintLabel.frame = NSRect(
                x: chevronView.frame.minX - 5 - hintW,
                y: floor((h - hintH) * 0.5),
                width: hintW,
                height: hintH
            )
        }
    }
}

private struct MacTranscriptTimelineListView: NSViewRepresentable {
    let entries: [MacTranscriptListEntry]
    let onToggleEarly: () -> Void
    let onSelectWindow: (DesktopTranscriptWindow) -> Void

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [MacTranscriptListEntry] = []
        var onToggleEarly: () -> Void
        var onSelectWindow: (DesktopTranscriptWindow) -> Void
        weak var tableView: MacTranscriptNSTableView?
        private var boundsObserver: NSObjectProtocol?

        init(
            onToggleEarly: @escaping () -> Void,
            onSelectWindow: @escaping (DesktopTranscriptWindow) -> Void
        ) {
            self.onToggleEarly = onToggleEarly
            self.onSelectWindow = onSelectWindow
        }

        deinit {
            if let obs = boundsObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        @MainActor
        func bindScroll(scrollView: NSScrollView, tableView: MacTranscriptNSTableView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak tableView] _ in
                MainActor.assumeIsolated {
                    tableView?.refreshHoverFromWindowMouse()
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard entries.indices.contains(row) else { return 64 }
            switch entries[row] {
            case .earlyHeader:
                return 44
            case let .window(_, _, headline, excerpt):
                if headline.isEmpty {
                    return excerpt.count > 36 ? 64 : 48
                }
                if excerpt.isEmpty { return 48 }
                return excerpt.count > 44 ? 82 : 66
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("TranscriptEntryCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? MacTranscriptRowCellView)
                ?? {
                    let v = MacTranscriptRowCellView(frame: .zero)
                    v.identifier = id
                    return v
                }()
            let hovered = (tableView as? MacTranscriptNSTableView)?.hoveredRow == row
            cell.configure(with: entries[row], hovered: hovered)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func handleClick(row: Int) {
            guard entries.indices.contains(row) else { return }
            switch entries[row] {
            case .earlyHeader:
                onToggleEarly()
            case let .window(item, _, _, _):
                onSelectWindow(item)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggleEarly: onToggleEarly, onSelectWindow: onSelectWindow)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 28, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = MacTranscriptNSTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TranscriptMainColumn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        let coord = context.coordinator
        coord.entries = entries
        coord.tableView = tableView
        tableView.dataSource = coord
        tableView.delegate = coord
        tableView.onPrimaryClickRow = { [weak coord] row in
            coord?.handleClick(row: row)
        }

        scrollView.documentView = tableView
        coord.bindScroll(scrollView: scrollView, tableView: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.onToggleEarly = onToggleEarly
        coord.onSelectWindow = onSelectWindow
        guard let tableView = coord.tableView else { return }
        if coord.entries != entries {
            coord.entries = entries
            tableView.reloadData()
        }
    }
}

private struct TranscriptStepButton: View {
    let symbol: String
    let enabled: Bool
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(enabled ? MoMoPalette.ink : MoMoPalette.muted.opacity(0.35))
                .frame(width: 24, height: 24)
                .background(
                    hovered && enabled ? MoMoPalette.hoverFill : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel(LocalizedStringKey(label))
    }
}

private struct TranscriptDateLabelButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MoMoPalette.muted)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(
                hovered ? MoMoPalette.hoverFill : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct TranscriptIconActionButton: View {
    let symbol: String
    let isActive: Bool
    let disabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let accessibilityID: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let btn = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive || hovered ? MoMoPalette.ink : MoMoPalette.muted)
                .frame(width: 28, height: 28)
                .momoElevatedCard(cornerRadius: 999, isFocused: isActive || hovered, shadowStrength: 0.45)
                .contentShape(Circle())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.94))
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(LocalizedStringKey(accessibilityLabel))

        if let accessibilityID {
            btn.accessibilityIdentifier(accessibilityID)
        } else {
            btn
        }
    }
}

private struct TranscriptBackButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("转录列表")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(hovered ? MoMoPalette.ink : MoMoPalette.muted)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .momoElevatedCard(cornerRadius: 999, isFocused: hovered, shadowStrength: 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.96))
        .onHover { hovered = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help("返回转录列表（⌘[）")
    }
}

/// Grok Bot `sand-kit-button` floating capsule CTA for asking MoMo about a transcript.
private struct SandTranscriptAskPillButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12.5, weight: .medium))
                Text("围绕这段录音向 MoMo 提问")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle(enabled ? MoMoPalette.canvas : MoMoPalette.muted)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(
                MoMoPalette.ink.opacity(enabled ? (hovered ? 0.88 : 1.0) : 0.08),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.97))
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityIdentifier("desktop.source.ask")
    }
}

struct DesktopSourceReader: View {
    let model: DesktopModel
    let source: ContextSource
    var window: ContextSourceWindow? = nil
    var initialSpanID: String? = nil
    @State private var pendingScrollSpanID: String?
    @State private var readRequest: UUID?
    var close: (() -> Void)?
    var onDiscuss: (() -> Void)? = nil
    @State private var page: SourceTextPage?
    @State private var text = ""
    @State private var spans: [SourceTextSpan] = []
    @State private var composedDocument: MacSourceTranscriptComposer.ComposedTranscript?
    @State private var loading = false
    @State private var error: String?

    private static let clockFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    private var recordedAt: Double? { window?.recordedAt ?? source.recordedAt }
    private var endAt: Double? { window?.endAt ?? recordedAt }
    private var summary: String? { window?.summary ?? source.summary }
    private var startOffset: Int { window?.offset ?? 0 }
    private var endOffset: Int { window?.end ?? source.totalCharacters }
    private var documentID: String { "\(source.id)|\(window?.id ?? "full")" }
    private var composeTriggerKey: String { "\(documentID)|\(source.revision)|\(spans.count)|\(text.utf8.count)" }
    private var hasMore: Bool {
        guard let page else { return true }
        guard let next = page.nextOffset else { return false }
        return next < endOffset
    }

    private var sourceTimeZone: TimeZone {
        window?.displayTimeZone() ?? .current
    }

    private var sourceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceTimeZone
        return calendar
    }

    private var headerDateLabel: String? {
        guard let timestamp = recordedAt else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return window?.naturalDay ?? DesktopTranscriptSnapshot.dayKey(for: date, calendar: sourceCalendar)
    }

    private var headerTimeLabel: String? {
        guard let timestamp = recordedAt else { return nil }
        let start = Date(timeIntervalSince1970: timestamp)
        let end = Date(timeIntervalSince1970: endAt ?? timestamp)
        var clock = Self.clockFormat
        clock.timeZone = sourceTimeZone
        let startLabel = start.formatted(clock)
        let endLabel = end.formatted(clock)
        return startLabel == endLabel ? startLabel : "\(startLabel)–\(endLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                DesktopWindowDragRegion()
                HStack {
                    if let close {
                        TranscriptBackButton(action: close)
                    }
                    Spacer()
                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在读取原文…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                    }
                    if !hasMore && !text.isEmpty {
                        ShareLink(item: text) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                                .foregroundStyle(MoMoPalette.muted)
                                .frame(width: 28, height: 28)
                                .momoElevatedCard(cornerRadius: 999, shadowStrength: 0.4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("分享完整原文")
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MoMoPalette.borderSubtle)
                    .frame(height: 0.5)
                    .allowsHitTesting(false)
            }

            MacSourceTranscriptReader(
                composed: composedDocument,
                scrollSpanID: pendingScrollSpanID,
                onConsumedScrollSpan: { pendingScrollSpanID = nil }
            )
            .momoScrollEdgeFade(top: 12, bottom: 20, surface: MoMoPalette.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if (!loading && hasMore) || error != nil {
                HStack(spacing: 12) {
                    if let error {
                        Text(error).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    }
                    Spacer(minLength: 0)
                    Button(error == nil ? "继续读取原文" : "重试读取") {
                        Task { await more(replacing: error != nil) }
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(MoMoPalette.pane)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer(minLength: 0)
                SandTranscriptAskPillButton(
                    enabled: model.taskStore != nil && (!text.isEmpty || summary != nil)
                ) {
                    guard let store = model.taskStore else { return }
                    let at = recordedAt.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day().hour().minute().second()) }
                    let reference = String(localized: "围绕") + (at.map { $0 + String(localized: "的") } ?? "") + String(localized: "这段录音，我想问：\n")
                    store.setDraft(store.draft.isEmpty ? reference : store.draft + "\n\n" + reference)
                    model.selection = "chat"
                    onDiscuss?()
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)
        }
        .onChange(of: initialSpanID, initial: true) { _, nextSpan in
            if let nextSpan { pendingScrollSpanID = nextSpan }
        }
        .task(id: composeTriggerKey) {
            let docID = documentID
            let rev = source.revision
            let dLabel = headerDateLabel
            let tLabel = headerTimeLabel
            let sum = summary
            let curSpans = spans
            let curText = text
            let tz = sourceTimeZone
            if let hit = MacSourceTranscriptComposer.cached(
                documentID: docID,
                sourceRevision: rev,
                dateLabel: dLabel,
                timeLabel: tLabel,
                summary: sum,
                spans: curSpans,
                fallbackText: curText,
                defaultTimeZone: tz
            ) {
                composedDocument = hit
                return
            }
            let built = await Task.detached(priority: .userInitiated) {
                MacSourceTranscriptComposer.compose(
                    documentID: docID,
                    sourceRevision: rev,
                    dateLabel: dLabel,
                    timeLabel: tLabel,
                    summary: sum,
                    spans: curSpans,
                    fallbackText: curText,
                    defaultTimeZone: tz
                )
            }.value
            guard !Task.isCancelled else { return }
            composedDocument = built
        }
        .task(id: "\(documentID)|\(source.revision)") { await more(replacing: true) }
    }

    private func more(replacing: Bool = false) async {
        guard replacing || (!loading && hasMore) else { return }
        let request = UUID()
        readRequest = request
        loading = true
        defer { if readRequest == request { loading = false } }
        var nextPage = replacing ? nil : page
        var nextText = replacing ? "" : text
        var nextSpans = replacing ? [] : spans
        var seenSpanIDs = Set(nextSpans.map(\.id))
        var pagesFetched = 0
        do {
            while nextPage == nil || (nextPage?.nextOffset.map { $0 < endOffset } ?? false) {
                let currentOffset = nextPage?.nextOffset ?? startOffset
                let pageLimit = min(16_000, max(1, endOffset - currentOffset))
                let next = try await model.readSource(source, offset: currentOffset, limit: pageLimit)
                try Task.checkCancellation()
                guard next.end > currentOffset || next.nextOffset == nil else { throw URLError(.cannotParseResponse) }
                if !nextText.isEmpty && !next.text.isEmpty && !nextText.hasSuffix("\n") {
                    nextText += "\n"
                }
                nextText += next.text
                if let incomingSpans = next.spans {
                    for span in incomingSpans where seenSpanIDs.insert(span.id).inserted {
                        nextSpans.append(span)
                    }
                }
                nextPage = next
                pagesFetched += 1
                let isLastPage = !(next.nextOffset.map { $0 < endOffset } ?? false)
                // Commit first page immediately for instant paint, then commit once when complete (eliminates O(N^2) intermediate relayouts).
                if pagesFetched == 1 || isLastPage {
                    guard readRequest == request else { return }
                    text = nextText
                    spans = nextSpans
                    page = nextPage
                    error = nil
                }
            }
        } catch is CancellationError {} catch {
            if readRequest == request { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Native AppKit 120fps Tiled Transcript Reader

private enum MacSourceTranscriptComposer {
    final class ComposedTranscript: NSObject, @unchecked Sendable {
        let key: String
        let documentID: String
        let attributedString: NSAttributedString
        let summaryCardRange: NSRange?
        let summaryQuoteRanges: [NSRange]
        let spanCharRanges: [String: NSRange]

        init(
            key: String,
            documentID: String,
            attributedString: NSAttributedString,
            summaryCardRange: NSRange?,
            summaryQuoteRanges: [NSRange],
            spanCharRanges: [String: NSRange]
        ) {
            self.key = key
            self.documentID = documentID
            self.attributedString = attributedString
            self.summaryCardRange = summaryCardRange
            self.summaryQuoteRanges = summaryQuoteRanges
            self.spanCharRanges = spanCharRanges
        }
    }

    private nonisolated(unsafe) static let cache: NSCache<NSString, ComposedTranscript> = {
        let c = NSCache<NSString, ComposedTranscript>()
        c.countLimit = 96
        return c
    }()

    private nonisolated static var inkColor: NSColor { NSColor(named: "PhoneInk") ?? .labelColor }
    private nonisolated static var mutedColor: NSColor { NSColor(named: "PhoneMuted") ?? .secondaryLabelColor }

    private nonisolated static func formatWallClock(timestamp: Double, offsetSeconds: Int) -> String {
        let localSeconds = Int(floor(timestamp)) + offsetSeconds
        let secOfDay = ((localSeconds % 86_400) + 86_400) % 86_400
        let hh = secOfDay / 3600
        let mm = (secOfDay % 3600) / 60
        let ss = secOfDay % 60
        return String(format: "%02d:%02d:%02d", hh, mm, ss)
    }

    private nonisolated static func makeCacheKey(
        documentID: String,
        sourceRevision: String,
        dateLabel: String?,
        timeLabel: String?,
        summary: String?,
        spans: [SourceTextSpan],
        fallbackText: String,
        defaultTimeZone: TimeZone
    ) -> String {
        var hasher = Hasher()
        hasher.combine(documentID)
        hasher.combine(sourceRevision)
        hasher.combine(dateLabel)
        hasher.combine(timeLabel)
        hasher.combine(summary)
        hasher.combine(spans.count)
        hasher.combine(spans.first?.id)
        hasher.combine(spans.last?.id)
        hasher.combine(fallbackText.utf8.count)
        hasher.combine(defaultTimeZone.identifier)
        return "v4|\(documentID)|\(sourceRevision)|\(spans.count)|\(fallbackText.utf8.count)|\(hasher.finalize())"
    }

    nonisolated static func cached(
        documentID: String,
        sourceRevision: String,
        dateLabel: String?,
        timeLabel: String?,
        summary: String?,
        spans: [SourceTextSpan],
        fallbackText: String,
        defaultTimeZone: TimeZone
    ) -> ComposedTranscript? {
        let key = makeCacheKey(
            documentID: documentID,
            sourceRevision: sourceRevision,
            dateLabel: dateLabel,
            timeLabel: timeLabel,
            summary: summary,
            spans: spans,
            fallbackText: fallbackText,
            defaultTimeZone: defaultTimeZone
        )
        return cache.object(forKey: key as NSString)
    }

    nonisolated static func compose(
        documentID: String,
        sourceRevision: String,
        dateLabel: String?,
        timeLabel: String?,
        summary: String?,
        spans: [SourceTextSpan],
        fallbackText: String,
        defaultTimeZone: TimeZone
    ) -> ComposedTranscript {
        let key = makeCacheKey(
            documentID: documentID,
            sourceRevision: sourceRevision,
            dateLabel: dateLabel,
            timeLabel: timeLabel,
            summary: summary,
            spans: spans,
            fallbackText: fallbackText,
            defaultTimeZone: defaultTimeZone
        )
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) {
            return hit
        }

        let ink = inkColor
        let muted = mutedColor
        let result = NSMutableAttributedString()
        var summaryCardRange: NSRange?
        var summaryQuotes: [NSRange] = []
        var spanRanges: [String: NSRange] = [:]
        spanRanges.reserveCapacity(spans.count)

        if let dateLabel, !dateLabel.isEmpty {
            let dateStyle = NSMutableParagraphStyle()
            dateStyle.lineSpacing = 3
            dateStyle.paragraphSpacing = (timeLabel?.isEmpty == false) ? 5 : 18
            result.append(NSAttributedString(
                string: dateLabel + "\n",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: muted,
                    .paragraphStyle: dateStyle,
                ]
            ))
        }

        if let timeLabel, !timeLabel.isEmpty {
            let timeStyle = NSMutableParagraphStyle()
            timeStyle.lineSpacing = 3
            timeStyle.paragraphSpacing = 18
            result.append(NSAttributedString(
                string: timeLabel + "\n",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium),
                    .kern: -0.3,
                    .foregroundColor: ink,
                    .paragraphStyle: timeStyle,
                ]
            ))
        }

        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cardInset: CGFloat = 22
            let cardStart = result.length
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.firstLineHeadIndent = cardInset
            headerStyle.headIndent = cardInset
            headerStyle.tailIndent = -cardInset
            headerStyle.paragraphSpacingBefore = 22
            headerStyle.paragraphSpacing = 10
            result.append(NSAttributedString(
                string: String(localized: "总结") + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: muted,
                    .paragraphStyle: headerStyle,
                ]
            ))

            let renderedSummary = MacMarkdownRenderer.render(markdown: summary, handwriting: false, plainTextOnly: false)
            let summaryMutable = NSMutableAttributedString(attributedString: renderedSummary.attributedString)
            if summaryMutable.length > 0 && !summaryMutable.string.hasSuffix("\n") {
                let tailAttrs = summaryMutable.attributes(at: summaryMutable.length - 1, effectiveRange: nil)
                summaryMutable.append(NSAttributedString(string: "\n", attributes: tailAttrs))
            } else if summaryMutable.length == 0 {
                summaryMutable.append(NSAttributedString(string: "\n"))
            }
            let fullRange = NSRange(location: 0, length: summaryMutable.length)
            summaryMutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
                let base = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                base.firstLineHeadIndent += cardInset
                base.headIndent += cardInset
                base.tailIndent = -cardInset
                if !base.tabStops.isEmpty {
                    base.tabStops = base.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + cardInset, options: $0.options) }
                }
                if NSMaxRange(range) >= summaryMutable.length {
                    base.paragraphSpacing = 0
                }
                summaryMutable.addAttribute(.paragraphStyle, value: base, range: range)
            }
            let bodyOffset = result.length
            result.append(summaryMutable)
            for qr in renderedSummary.quoteCharRanges {
                summaryQuotes.append(NSRange(location: qr.location + bodyOffset, length: qr.length))
            }
            summaryCardRange = NSRange(location: cardStart, length: result.length - cardStart)
        }

        let visibleSpans = spans.filter { ($0.text ?? "").isEmpty == false }
        if !visibleSpans.isEmpty {
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 6.2
            bodyStyle.paragraphSpacing = 16
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13.8, weight: .regular),
                .foregroundColor: ink,
                .paragraphStyle: bodyStyle,
            ]

            let firstStampStyle = NSMutableParagraphStyle()
            firstStampStyle.paragraphSpacingBefore = summaryCardRange != nil ? 42 : 6
            firstStampStyle.paragraphSpacing = 5
            let stampStyle = NSMutableParagraphStyle()
            stampStyle.paragraphSpacing = 5
            let stampFont = NSFont.monospacedDigitSystemFont(ofSize: PhoneTextStyle.caption.size, weight: .regular)

            let fixedDefaultOffset: Int? = defaultTimeZone.isDaylightSavingTime() ? nil : defaultTimeZone.secondsFromGMT()

            for (idx, span) in visibleSpans.enumerated() {
                let spanStart = result.length
                if let spanTime = span.recordedAt {
                    let offsetSec = span.timezoneOffset
                        ?? fixedDefaultOffset
                        ?? defaultTimeZone.secondsFromGMT(for: Date(timeIntervalSince1970: spanTime))
                    let clock = formatWallClock(timestamp: spanTime, offsetSeconds: offsetSec)
                    result.append(NSAttributedString(
                        string: clock + "\n",
                        attributes: [
                            .font: stampFont,
                            .foregroundColor: muted,
                            .paragraphStyle: idx == 0 ? firstStampStyle : stampStyle,
                        ]
                    ))
                } else if idx == 0, summaryCardRange != nil {
                    let topBodyStyle = bodyStyle.mutableCopy() as! NSMutableParagraphStyle
                    topBodyStyle.paragraphSpacingBefore = 42
                    result.append(NSAttributedString(
                        string: (span.text ?? "") + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13.8, weight: .regular),
                            .foregroundColor: ink,
                            .paragraphStyle: topBodyStyle,
                        ]
                    ))
                    spanRanges[span.id] = NSRange(location: spanStart, length: result.length - spanStart)
                    continue
                }
                result.append(NSAttributedString(string: (span.text ?? "") + "\n", attributes: bodyAttrs))
                spanRanges[span.id] = NSRange(location: spanStart, length: result.length - spanStart)
            }
        } else if !fallbackText.isEmpty {
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.paragraphSpacingBefore = summaryCardRange != nil ? 42 : 6
            bodyStyle.lineSpacing = 6.2
            bodyStyle.paragraphSpacing = 14
            result.append(NSAttributedString(
                string: fallbackText + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13.8, weight: .regular),
                    .foregroundColor: ink,
                    .paragraphStyle: bodyStyle,
                ]
            ))
        }

        let composed = ComposedTranscript(
            key: key,
            documentID: documentID,
            attributedString: result,
            summaryCardRange: summaryCardRange,
            summaryQuoteRanges: summaryQuotes,
            spanCharRanges: spanRanges
        )
        cache.setObject(composed, forKey: nsKey)
        return composed
    }
}

private final class MacSourceDocumentTextView: NSTextView {
    var currentComposedKey: String = "" {
        didSet {
            if currentComposedKey != oldValue {
                cachedSummaryCardRect = nil
            }
        }
    }
    var currentDocumentID: String = ""
    var summaryCardRange: NSRange? {
        didSet { cachedSummaryCardRect = nil }
    }
    var summaryQuoteRanges: [NSRange] = []

    private var cachedSummaryCardRect: NSRect?
    private var cachedSummaryWidth: CGFloat = -1
    private var cachedSummaryOrigin: NSPoint = .zero

    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.size.width) >= 0.5 {
            cachedSummaryCardRect = nil
        }
        super.setFrameSize(newSize)
    }

    private func resolvedSummaryCardRect() -> NSRect? {
        guard let cardRange = summaryCardRange,
              let lm = layoutManager, let tc = textContainer, let ts = textStorage,
              cardRange.location >= 0, NSMaxRange(cardRange) <= ts.length else {
            return nil
        }
        let cw = tc.containerSize.width
        let origin = textContainerOrigin
        if let cached = cachedSummaryCardRect,
           abs(cachedSummaryWidth - cw) < 0.5,
           abs(cachedSummaryOrigin.x - origin.x) < 0.5,
           abs(cachedSummaryOrigin.y - origin.y) < 0.5 {
            return cached
        }
        let glyphRange = lm.glyphRange(forCharacterRange: cardRange, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        guard rect.height > 4 else { return nil }
        let bgRect = NSRect(
            x: origin.x,
            y: origin.y + rect.minY - 18,
            width: cw,
            height: rect.height + 36
        )
        cachedSummaryCardRect = bgRect
        cachedSummaryWidth = cw
        cachedSummaryOrigin = origin
        return bgRect
    }

    override func draw(_ dirtyRect: NSRect) {
        if let bgRect = resolvedSummaryCardRect(), bgRect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: bgRect, xRadius: 14, yRadius: 14)
            (NSColor(named: "PhoneSurface") ?? .quaternaryLabelColor).setFill()
            path.fill()
            (NSColor(named: "PhoneInk") ?? .labelColor).withAlphaComponent(0.065).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
        if !summaryQuoteRanges.isEmpty,
           let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            let origin = textContainerOrigin
            let totalLen = ts.length
            (NSColor(named: "PhoneLine") ?? .separatorColor).setFill()
            for charRange in summaryQuoteRanges where charRange.location >= 0 && NSMaxRange(charRange) <= totalLen {
                let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                guard rect.height > 1 else { continue }
                let barRect = NSRect(
                    x: origin.x + 22.5,
                    y: origin.y + rect.minY + 1,
                    width: 2.0,
                    height: max(4, rect.height - 2)
                )
                if barRect.intersects(dirtyRect) {
                    NSBezierPath(roundedRect: barRect, xRadius: 1.0, yRadius: 1.0).fill()
                }
            }
        }
    }
}

private final class MacSourceDocumentScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? MacSourceDocumentTextView else { return }
        let vw = max(220, contentView.bounds.width)
        let readableWidth = max(180, min(632, floor(vw - 48)))
        let sideInset = max(24, floor((vw - readableWidth) * 0.5))
        if abs(tv.textContainerInset.width - sideInset) >= 0.5 || abs(tv.textContainerInset.height - 28) >= 0.5 {
            tv.textContainerInset = NSSize(width: sideInset, height: 28)
        }
        if abs(tv.frame.width - vw) >= 0.5 {
            tv.setFrameSize(NSSize(width: vw, height: tv.frame.height))
        }
    }
}

private struct MacSourceTranscriptReader: NSViewRepresentable {
    let composed: MacSourceTranscriptComposer.ComposedTranscript?
    let scrollSpanID: String?
    let onConsumedScrollSpan: () -> Void

    final class Coordinator: NSObject {
        weak var textView: MacSourceDocumentTextView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MacSourceDocumentScrollView {
        let scrollView = MacSourceDocumentScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = MacSourceDocumentTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 24, height: 28)
        textView.textContainer?.containerSize = NSSize(width: 592, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityIdentifier("desktop.source.text")

        context.coordinator.textView = textView
        scrollView.documentView = textView
        apply(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: MacSourceDocumentScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, in: scrollView)
    }

    private func apply(to textView: MacSourceDocumentTextView, in scrollView: MacSourceDocumentScrollView) {
        guard let composed else { return }
        let documentChanged = textView.currentDocumentID != composed.documentID
        if textView.currentComposedKey != composed.key {
            let previousOrigin = scrollView.contentView.bounds.origin
            textView.currentComposedKey = composed.key
            textView.currentDocumentID = composed.documentID
            textView.summaryCardRange = composed.summaryCardRange
            textView.summaryQuoteRanges = composed.summaryQuoteRanges
            if documentChanged, textView.selectedRange().length > 0 {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            textView.textStorage?.setAttributedString(composed.attributedString)
            textView.needsDisplay = true
            if documentChanged {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else if previousOrigin.y > 0 {
                scrollView.contentView.scroll(to: previousOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        if let targetID = scrollSpanID,
           let charRange = composed.spanCharRanges[targetID],
           let lm = textView.layoutManager,
           let tc = textView.textContainer {
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(charRange)))
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let targetY = max(0, textView.textContainerOrigin.y + rect.minY - 14)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async {
                onConsumedScrollSpan()
            }
        }
    }
}

/// Keep source navigation inside MoMo; Launch Services cannot resolve private recording URLs.
struct DesktopRecordingCitation: View {
    let model: DesktopModel
    let citation: RecordingCitation
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var retry = 0
    @State private var showingFullTranscript = false

    private enum LoadState {
        case loading, loaded(ResolvedRecordingCitation), failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("录音原文").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            switch state {
            case .loading:
                ProgressView("正在读取原文").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("暂时无法打开录音", systemImage: "waveform")
                } description: { Text(message) } actions: {
                    Button("重试") { retry += 1 }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let resolved):
                if showingFullTranscript {
                    DesktopSourceReader(model: model, source: resolved.source, close: { showingFullTranscript = false }, onDiscuss: { dismiss() })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let time = resolved.span.recordedAt {
                                Text(Date(timeIntervalSince1970: time).formatted(.dateTime.year().month().day().hour().minute().second()))
                                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                            }
                            if resolved.showsUpdatedTranscript {
                                Text("录音已有更新，以下为当前原文。")
                                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                            }
                            TranscriptParagraphText(text: resolved.span.text ?? "", accessibilityID: "desktop.citation.text")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("查看完整转录") { showingFullTranscript = true }
                    }.padding(20)
                }
            }
        }
        .frame(width: 640, height: 540)
        .background(MoMoPalette.canvas)
        .task(id: retry) {
            state = .loading
            do {
                let result = try await model.readRecordingCitation(citation)
                try Task.checkCancellation()
                state = .loaded(result)
            } catch is CancellationError { }
            catch { state = .failed(error.localizedDescription) }
        }
    }
}
