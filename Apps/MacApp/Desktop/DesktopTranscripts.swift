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
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var observedToday = Calendar.current.startOfDay(for: Date())
    @State private var selectedID: String?
    @State private var query = ""
    @State private var searching = false
    @State private var choosingDate = false
    @State private var selectedIllustrationID: String?
    @State private var illustrationError: String?
    @State private var timelineAnchor: String?
    @State private var savedAnchors: [String: String] = [:]
    @State private var expandedDays: [String: Bool] = [:]
    @State private var selectedSpanID: String?
    private var selectedDayKey: String { DesktopTranscriptSnapshot.dayKey(for: day, calendar: calendar) }
    private func isEarly(_ item: DesktopTranscriptWindow) -> Bool {
        guard let timestamp = item.recordedAt else { return false }
        let date = Date(timeIntervalSince1970: timestamp)
        return TranscriptReadingBoundary.isEarly(date,
            offset: item.window.displayTimeZone().secondsFromGMT(for: date), hour: model.dayStartHour)
    }
    private var earlyExpanded: Bool {
        expandedDays[selectedDayKey] ?? TranscriptReadingBoundary.initiallyExpanded(
            hasDaytime: visible.contains { !isEarly($0) }, isToday: calendar.isDate(day, inSameDayAs: logicalToday),
            hour: model.dayStartHour)
    }
    private let calendar = Calendar.current

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
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720
            HStack(spacing: 0) {
                if wide || (selected == nil && selectedIllustration == nil) {
                    timeline
                        .frame(width: wide ? 340 : nil)
                        .frame(maxWidth: wide ? nil : .infinity)
                        .clipped()
                }
                if wide { Divider() }
                if let illustration = selectedIllustration {
                    Group {
                        if dayIllustrations.contains(where: { $0.coordinate != nil }) {
                            LifeIllustrationJourneyMapView(store: model.lifeIllustrations, initialID: illustration.id, referenceDay: selectedDayKey,
                                close: closeIllustration, showSource: { showSource(for: $0) })
                        } else {
                            LifeIllustrationViewer(store: model.lifeIllustrations, initialID: illustration.id, referenceDay: selectedDayKey,
                                close: closeIllustration, showSource: { showSource(for: $0) })
                        }
                    }
                    .id(selectedDayKey)
                    .frame(maxWidth: .infinity)
                } else if let selected {
                    DesktopSourceReader(
                        model: model,
                        source: selected.source,
                        window: selected.window,
                        initialSpanID: selectedSpanID,
                        close: wide ? nil : { selectedID = nil }
                    )
                    .id(selected.id)
                    .frame(maxWidth: .infinity)
                } else if wide {
                    ContentUnavailableView("选择一段转录", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(MoMoPalette.canvas)
        .task(id: isActive) {
            guard isActive else { return }
            let initialToday = logicalToday
            observedToday = initialToday
            await model.loadContextIfStale(maxAge: 8)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { break }
                let today = logicalToday
                if today != observedToday {
                    observedToday = today
                }
                await model.loadContext(silent: true)
            }
        }
        .onChange(of: model.dayStartHour) {
            expandedDays.removeAll()
            expandedDays[selectedDayKey] = TranscriptReadingBoundary.initiallyExpanded(
                hasDaytime: visible.contains { !isEarly($0) }, isToday: calendar.isDate(day, inSameDayAs: logicalToday),
                hour: model.dayStartHour)
        }
        .onChange(of: selectedDayKey) { _, new in
            timelineAnchor = savedAnchors[new] ?? "masthead"
        }
        .onChange(of: timelineAnchor) { _, value in
            if let value { savedAnchors[selectedDayKey] = value }
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
        let windows = !query.isEmpty || expanded ? currentVisible : daytime
        let currentDayIllustrations = (!searching && query.isEmpty) ? dayIllustrations : []
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("转录").font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.loadContext() } }
                    .labelStyle(.iconOnly).buttonStyle(.plain).disabled(model.contextLoading)
                    .help("刷新转录").accessibilityIdentifier("desktop.transcripts.refresh")
            }.padding(.horizontal, 24).padding(.top, 12)
            dateBar
            if searching {
                TextField("搜索已同步的摘要与片段", text: $query).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 24).accessibilityIdentifier("desktop.transcripts.search")
            }
            if let error = model.memoryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
                    Button("重试") { Task { await model.loadContext() } }
                }.padding(.horizontal, 24)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                Color.clear.frame(height: 1).id("masthead")
                if !currentDayIllustrations.isEmpty {
                    LifeIllustrationStripView(items: currentDayIllustrations, store: model.lifeIllustrations, horizontalMargin: 16,
                        open: { selectedIllustrationID = $0.id }, showSource: { showSource(for: $0) },
                        failure: { illustrationError = $0 })
                        .padding(.bottom, 8)
                }
                    if query.isEmpty, !early.isEmpty {
                        Button {
                            expandedDays[selectedDayKey] = !expanded
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                Text("凌晨记录 · \(early.count) 段")
                                Spacer()
                                Text("00:00–" + TranscriptReadingBoundary.label(for: model.dayStartHour))
                            }.phoneText(.caption).foregroundStyle(MoMoPalette.muted).frame(minHeight: 44)
                        }.buttonStyle(.plain).padding(.horizontal, 12)
                            .accessibilityIdentifier("desktop.transcripts.early.toggle")
                            .accessibilityValue(expanded ? "已展开" : "已折叠")
                    }
                    ForEach(windows) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                closeIllustration()
                                selectedSpanID = nil
                                if !query.isEmpty {
                                    selectSourceDay(item.logicalDayKey)
                                    expandedDays[item.logicalDayKey] = true
                                }
                                selectedID = item.id
                            } label: {
                                ClientTranscriptRow(
                                    time: query.isEmpty ? item.rangeTimeLabel : item.datedTimeLabel,
                                    preview: item.displayPreview,
                                    status: nil,
                                    connected: item.id != windows.last?.id,
                                    isFinal: true,
                                    continuesFromPrevious: item.id != windows.first?.id
                                ) {
                                    EmptyView()
                                }
                                .padding(.horizontal, 12)
                                .background(selectedID == item.id && selectedIllustrationID == nil ? MoMoPalette.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("desktop.source.\(item.id)")
                            .accessibilityAddTraits(selectedID == item.id && selectedIllustrationID == nil ? [.isSelected] : [])
                        }
                        .id(item.id)
                    }
                    if query.isEmpty, !early.isEmpty, !hasDaytime {
                        Text("当天暂无 \(TranscriptReadingBoundary.label(for: model.dayStartHour)) 后记录")
                            .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    }
                    if windows.isEmpty && !model.contextLoading && model.memoryError == nil {
                        ContentUnavailableView(
                            query.isEmpty ? "这一天还没有转录" : "没有匹配的转录",
                            systemImage: "waveform",
                            description: Text(query.isEmpty ? "手机同步的录音稿会按日期出现在这里。" : "搜索范围为已同步的摘要与原文片段。")
                        )
                        if query.isEmpty, snapshot.latestRecordedAt != nil,
                           snapshot.ordered.last?.logicalDayKey != selectedDayKey {
                            Button("查看最近的转录") { if let key = snapshot.ordered.last?.logicalDayKey { selectSourceDay(key) } }
                        }
                    }
                    if model.contextLoading && windows.isEmpty { ProgressView("正在读取记录").padding(24) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                Spacer().frame(height: 24)
            }
            .scrollPosition(id: $timelineAnchor, anchor: .top)
            .onChange(of: currentVisible.isEmpty, initial: true) { _, empty in
                if !empty, expandedDays[selectedDayKey] == nil { expandedDays[selectedDayKey] = expanded }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        savedAnchors[key] = source.id
        timelineAnchor = source.id
    }

    private var dateBar: some View {
        HStack(spacing: 0) {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                .disabled(day <= earliest || !query.isEmpty).accessibilityLabel("前一天")
            Button { choosingDate = true } label: {
                HStack(spacing: 5) {
                    Text(query.isEmpty ? dayTitle(day) : String(localized: "全部日期")).phoneText(.metadata)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.popover(isPresented: $choosingDate) {
                VStack(spacing: 14) {
                    DatePicker("选择日期", selection: $day, in: earliest...latestSelectableDay, displayedComponents: .date).datePickerStyle(.graphical)
                    HStack {
                        Button("今天") { day = logicalToday; query = ""; choosingDate = false }
                        Spacer()
                        Button("完成") { query = ""; choosingDate = false }
                    }
                }.padding(20).frame(width: 300)
            }
            Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                .disabled(day >= latestSelectableDay || !query.isEmpty).accessibilityLabel("后一天")
            Button { searching.toggle(); if !searching { query = "" } } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass").frame(width: 36, height: 44)
            }.accessibilityLabel(searching ? "关闭搜索" : "搜索转录")
        }.buttonStyle(.plain).foregroundStyle(MoMoPalette.ink).padding(.horizontal, 16)
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
    @State private var loading = false
    @State private var error: String?

    private static let clockFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    private var recordedAt: Double? { window?.recordedAt ?? source.recordedAt }
    private var endAt: Double? { window?.endAt ?? recordedAt }
    private var summary: String? { window?.summary ?? source.summary }
    private var startOffset: Int { window?.offset ?? 0 }
    private var endOffset: Int { window?.end ?? source.totalCharacters }
    private var documentID: String { "\(source.id)|\(window?.id ?? "full")" }
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
            HStack {
                if let close { Button("返回", action: close).buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Text("转录详情").font(.system(size: 14, weight: .medium))
                Spacer()
                if !hasMore && !text.isEmpty {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.plain).help("分享完整原文")
                }
            }.padding(.horizontal, 24).frame(height: 44)

            MacSourceTranscriptReader(
                documentID: documentID,
                sourceRevision: source.revision,
                dateLabel: headerDateLabel,
                timeLabel: headerTimeLabel,
                summary: summary,
                spans: spans,
                fallbackText: text,
                defaultTimeZone: sourceTimeZone,
                scrollSpanID: pendingScrollSpanID,
                onConsumedScrollSpan: { pendingScrollSpanID = nil }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if loading || hasMore || error != nil {
                HStack(spacing: 12) {
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("正在读取原文").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                    if let error {
                        Text(error).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    }
                    Spacer(minLength: 0)
                    if (!loading && hasMore) || error != nil {
                        Button(error == nil ? "继续读取原文" : "重试读取") {
                            Task { await more(replacing: error != nil) }
                        }
                        .buttonStyle(.plain)
                        .disabled(loading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !text.isEmpty {
                TranscriptDiscussAction(title: "围绕这段录音提问", enabled: model.taskStore != nil) {
                    guard let store = model.taskStore else { return }
                    let at = recordedAt.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day().hour().minute().second()) }
                    let reference = String(localized: "围绕") + (at.map { $0 + String(localized: "的") } ?? "") + String(localized: "这段录音，我想问：\n")
                    store.setDraft(store.draft.isEmpty ? reference : store.draft + "\n\n" + reference)
                    model.selection = "chat"
                    onDiscuss?()
                }.frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: initialSpanID, initial: true) { _, nextSpan in
            if let nextSpan { pendingScrollSpanID = nextSpan }
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
                let pageLimit = min(12_000, max(1, endOffset - currentOffset))
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
                if pagesFetched == 1 || isLastPage || pagesFetched.isMultiple(of: 2) {
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

    private static var inkColor: NSColor { NSColor(named: "PhoneInk") ?? .labelColor }
    private static var mutedColor: NSColor { NSColor(named: "PhoneMuted") ?? .secondaryLabelColor }

    private static func formatWallClock(timestamp: Double, offsetSeconds: Int) -> String {
        let localSeconds = Int(floor(timestamp)) + offsetSeconds
        let secOfDay = ((localSeconds % 86_400) + 86_400) % 86_400
        let hh = secOfDay / 3600
        let mm = (secOfDay % 3600) / 60
        let ss = secOfDay % 60
        return String(format: "%02d:%02d:%02d", hh, mm, ss)
    }

    static func compose(
        documentID: String,
        sourceRevision: String,
        dateLabel: String?,
        timeLabel: String?,
        summary: String?,
        spans: [SourceTextSpan],
        fallbackText: String,
        defaultTimeZone: TimeZone
    ) -> ComposedTranscript {
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
        let key = "\(documentID)|\(sourceRevision)|\(spans.count)|\(fallbackText.utf8.count)|\(hasher.finalize())"
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
            dateStyle.paragraphSpacing = (timeLabel?.isEmpty == false) ? 8 : 20
            result.append(NSAttributedString(
                string: dateLabel + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: PhoneTextStyle.metadata.size, weight: .regular),
                    .foregroundColor: muted,
                    .paragraphStyle: dateStyle,
                ]
            ))
        }

        if let timeLabel, !timeLabel.isEmpty {
            let timeStyle = NSMutableParagraphStyle()
            timeStyle.lineSpacing = 4
            timeStyle.paragraphSpacing = 20
            result.append(NSAttributedString(
                string: timeLabel + "\n",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: PhoneTextStyle.heading.size, weight: .medium),
                    .foregroundColor: ink,
                    .paragraphStyle: timeStyle,
                ]
            ))
        }

        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cardInset: CGFloat = 18
            let cardStart = result.length
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.firstLineHeadIndent = cardInset
            headerStyle.headIndent = cardInset
            headerStyle.tailIndent = -cardInset
            headerStyle.paragraphSpacingBefore = 14
            headerStyle.paragraphSpacing = 8
            result.append(NSAttributedString(
                string: String(localized: "总结") + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: PhoneTextStyle.menu.size, weight: .semibold),
                    .foregroundColor: ink,
                    .paragraphStyle: headerStyle,
                ]
            ))

            let renderedSummary = MacMarkdownRenderer.render(markdown: summary, handwriting: false, plainTextOnly: false)
            let summaryMutable = NSMutableAttributedString(attributedString: renderedSummary.attributedString)
            if summaryMutable.length == 0 || !summaryMutable.string.hasSuffix("\n") {
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
                    base.paragraphSpacing = max(base.paragraphSpacing, 14)
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
            bodyStyle.lineSpacing = 4.5
            bodyStyle.paragraphSpacing = 18
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: PhoneTextStyle.body.size, weight: .regular),
                .foregroundColor: ink,
                .paragraphStyle: bodyStyle,
            ]

            let firstStampStyle = NSMutableParagraphStyle()
            firstStampStyle.paragraphSpacingBefore = summaryCardRange != nil ? 22 : 4
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
                    topBodyStyle.paragraphSpacingBefore = 22
                    result.append(NSAttributedString(
                        string: (span.text ?? "") + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: PhoneTextStyle.body.size, weight: .regular),
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
            bodyStyle.paragraphSpacingBefore = summaryCardRange != nil ? 22 : 4
            bodyStyle.lineSpacing = 4.5
            bodyStyle.paragraphSpacing = 12
            result.append(NSAttributedString(
                string: fallbackText + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: PhoneTextStyle.body.size, weight: .regular),
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
    var currentComposedKey: String = ""
    var currentDocumentID: String = ""
    var summaryCardRange: NSRange?
    var summaryQuoteRanges: [NSRange] = []

    override func draw(_ dirtyRect: NSRect) {
        if let cardRange = summaryCardRange,
           let lm = layoutManager, let tc = textContainer, let ts = textStorage,
           cardRange.location >= 0, NSMaxRange(cardRange) <= ts.length {
            let glyphRange = lm.glyphRange(forCharacterRange: cardRange, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            if rect.height > 4 {
                let origin = textContainerOrigin
                let bgRect = NSRect(
                    x: origin.x,
                    y: origin.y + rect.minY + 2,
                    width: tc.containerSize.width,
                    height: rect.height + 2
                )
                if bgRect.intersects(dirtyRect) {
                    (NSColor(named: "PhoneSurface") ?? .quaternaryLabelColor).setFill()
                    NSBezierPath(roundedRect: bgRect, xRadius: 16, yRadius: 16).fill()
                }
            }
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
                    x: origin.x + 18.5,
                    y: origin.y + rect.minY + 1,
                    width: 2.5,
                    height: max(4, rect.height - 2)
                )
                if barRect.intersects(dirtyRect) {
                    NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
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
        if abs(tv.textContainerInset.width - sideInset) >= 0.5 || abs(tv.textContainerInset.height - 20) >= 0.5 {
            tv.textContainerInset = NSSize(width: sideInset, height: 20)
        }
        if abs(tv.frame.width - vw) >= 0.5 {
            tv.setFrameSize(NSSize(width: vw, height: tv.frame.height))
        }
    }
}

private struct MacSourceTranscriptReader: NSViewRepresentable {
    let documentID: String
    let sourceRevision: String
    let dateLabel: String?
    let timeLabel: String?
    let summary: String?
    let spans: [SourceTextSpan]
    let fallbackText: String
    let defaultTimeZone: TimeZone
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
        textView.textContainerInset = NSSize(width: 24, height: 20)
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
        let composed = MacSourceTranscriptComposer.compose(
            documentID: documentID,
            sourceRevision: sourceRevision,
            dateLabel: dateLabel,
            timeLabel: timeLabel,
            summary: summary,
            spans: spans,
            fallbackText: fallbackText,
            defaultTimeZone: defaultTimeZone
        )
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
