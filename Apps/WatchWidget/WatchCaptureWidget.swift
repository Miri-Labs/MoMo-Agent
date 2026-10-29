import SwiftUI
import WidgetKit
import MoMoContracts

@main
struct WatchCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetStore.kind, provider: CaptureTimelineProvider()) { entry in
            CaptureWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(WatchWidgetRequest().url(scheme: WatchWidgetStore.urlScheme))
        }
        .configurationDisplayName("随身录音")
        .description("查看录音状态、已录时长和待确认片段，轻点进入录音。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct CaptureWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchWidgetSnapshot?
    var unavailable = false

    var fresh: Bool { snapshot?.isFresh(at: date) == true }
    var queueLabel: String {
        guard let count = snapshot?.pendingChunkCount else { return fresh ? String(localized: "同步记录读取中") : String(localized: "同步状态待确认") }
        return String(localized: "\(fresh ? "" : String(localized: "上次："))\(count) 段待确认")
    }
    var compactQueueLabel: String {
        snapshot?.pendingChunkCount.map { String(localized: "\($0) 段待确认") } ?? (fresh ? String(localized: "同步读取中") : String(localized: "状态待确认"))
    }
    var title: String {
        guard let snapshot else { return unavailable ? String(localized: "状态暂不可用") : String(localized: "开始记录") }
        guard fresh else { return String(localized: "打开确认状态") }
        return switch snapshot.activity {
        case .idle, .stopped: String(localized: "尚未录音")
        case .preparing: String(localized: "准备录音")
        case .recording: String(localized: "正在录音")
        case .paused: String(localized: "已暂停")
        case .interrupted: String(localized: "录音已中断")
        case .failed: String(localized: "录音需检查")
        }
    }
    var symbol: String {
        guard fresh, let snapshot else { return "questionmark.circle" }
        return switch snapshot.activity {
        case .recording: "waveform"
        case .paused: "pause.fill"
        case .interrupted, .failed: "exclamationmark.mic.fill"
        case .preparing: "hourglass"
        case .idle, .stopped: "mic"
        }
    }
    var tint: Color {
        guard fresh, let snapshot else { return .secondary }
        return switch snapshot.activity {
        case .recording: .red
        case .interrupted, .failed: .orange
        case .paused, .preparing, .idle, .stopped: .secondary
        }
    }
    var control: (title: String, symbol: String, request: WatchWidgetRequest) {
        guard fresh, let snapshot else { return (String(localized: "打开录音"), "arrow.up.forward", WatchWidgetRequest()) }
        switch snapshot.activity {
        case .recording:
            return (String(localized: "暂停录音"), "pause.fill", snapshot.request(.pause))
        case .paused, .interrupted:
            return (String(localized: "继续录音"), "play.fill", snapshot.request(.resume))
        case .idle, .stopped:
            return (String(localized: "开始录音"), "mic.fill", snapshot.request(.start))
        case .preparing, .failed:
            return (String(localized: "查看录音"), "arrow.up.forward", WatchWidgetRequest())
        }
    }
    var duration: String {
        let seconds = min(max(0, snapshot?.capturedDuration ?? 0), 999 * 3600)
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct CaptureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureWidgetEntry {
        CaptureWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureWidgetEntry>) -> Void) {
        let now = Date()
        let entry = load(at: now)
        var entries = [entry]
        if let expiry = entry.snapshot?.expiresAt, expiry > now {
            // Expiry is precomputed, so an app suspension cannot leave an unbounded green timer.
            entries.append(CaptureWidgetEntry(date: expiry, snapshot: entry.snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
    }

    private func load(at date: Date) -> CaptureWidgetEntry {
        do { return CaptureWidgetEntry(date: date, snapshot: try WatchWidgetStore.shared().read()) }
        catch { return CaptureWidgetEntry(date: date, snapshot: nil, unavailable: true) }
    }
}

struct CaptureWidgetView: View {
    let entry: CaptureWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline:
            Label(entry.title, systemImage: entry.symbol)
        case .accessoryCorner:
            Image(systemName: entry.symbol)
                .font(.title2)
                .widgetAccentable()
                .widgetLabel { Text(entry.title) }
                .accessibilityLabel(entry.title)
        default:
            VStack(spacing: 2) {
                Image(systemName: entry.symbol).font(.title3).foregroundStyle(entry.tint)
                Text(entry.fresh ? entry.duration : String(localized: "查看"))
                    .font(.caption2).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.title)
            .accessibilityValue(entry.fresh ? String(localized: "已录 \(entry.duration)") : String(localized: "轻点打开录音"))
        }
    }

    private var rectangular: some View {
        ViewThatFits(in: .vertical) {
            rectangularContent(compact: false)
            rectangularContent(compact: true)
        }
    }

    private func rectangularContent(compact: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.title, systemImage: entry.symbol)
                    .font(.headline).foregroundStyle(entry.tint).lineLimit(1).minimumScaleFactor(0.8)
                if entry.snapshot != nil {
                    HStack(spacing: 5) {
                        Text(entry.duration)
                            .font(compact ? .caption : .system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        if compact {
                            Text("· \(entry.compactQueueLabel)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1).minimumScaleFactor(0.8)
                    if !compact {
                        Text(entry.queueLabel)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !compact, let date = entry.snapshot?.observedAt {
                        HStack(spacing: 3) {
                            Text("确认于")
                            Text(date, style: .time)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("MoMo Agent").font(.caption).foregroundStyle(.secondary)
                    if !compact { Text("轻点打开录音").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: entry.control.request.url(scheme: WatchWidgetStore.urlScheme)) {
                Image(systemName: entry.control.symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(entry.control.title)
            .accessibilityHint("打开手表 App 后执行，离开界面后可继续录音")
        }
    }
}

#Preview(as: .accessoryRectangular) {
    WatchCaptureWidget()
} timeline: {
    let now = Date()
    CaptureWidgetEntry(date: now, snapshot: WatchWidgetSnapshot(runtimeID: UUID(), generation: 1,
        observedAt: now, sessionID: UUID(), activity: .recording,
        capturedDuration: 754, pendingChunkCount: 2, lastSampleAt: now))
}
