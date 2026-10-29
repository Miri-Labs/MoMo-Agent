import SwiftUI
import MoMoArchive

extension View {
    func recordingSourceLinks(archive: ArchiveStore,
                              playback: AudioPlaybackController, openRecording: ((UUID) -> Void)? = nil) -> some View {
        modifier(RecordingSourceLinkModifier(archive: archive, playback: playback, openRecording: openRecording))
    }
}

enum RecordingSourceURL {
    enum Destination: Equatable {
        case source(SourceReference), web, unavailable
    }

    static func destination(for url: URL) -> Destination {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host?.isEmpty == false ? .web : .unavailable
        case "momoagent":
            guard let source = source(for: url) else { return .unavailable }
            return .source(source)
        default: return .unavailable
        }
    }

    /// Parse identity only. SourceExcerptView validates against ArchiveStore before showing
    /// text/audio, including unchanged spans in historical versions. The sync cache is
    /// neither an authorization list nor a complete index of older/offline citations.
    static func source(for url: URL) -> SourceReference? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "momoagent", components.host?.lowercased() == "source",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty,
              let sessionID = UUID(uuidString: String(path[1])),
              let spanID = UUID(uuidString: String(path[2])),
              let query = components.queryItems, query.count == 2,
              Set(query.map(\.name)) == Set(["version", "generation"]),
              let versionString = query.first(where: { $0.name == "version" })?.value,
              let generationString = query.first(where: { $0.name == "generation" })?.value,
              let version = Int64(versionString), let generation = Int64(generationString),
              version > 0, generation >= 0,
              versionString == String(version), generationString == String(generation) else { return nil }
        return SourceReference(sessionID: sessionID, spanID: spanID, transcriptVersion: version, generation: generation)
    }
}

private struct RecordingSourceLinkModifier: ViewModifier {
    let archive: ArchiveStore
    let playback: AudioPlaybackController
    @State private var selected: SelectedSource?
    let openRecording: ((UUID) -> Void)?
    @State private var openAfterDismiss: UUID?
    @State private var unavailable = false

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                switch RecordingSourceURL.destination(for: url) {
                case .web: return .systemAction
                case .source(let source):
                    selected = SelectedSource(source: source)
                case .unavailable: unavailable = true
                }
                return .handled
            })
            .sheet(item: $selected, onDismiss: {
                if let id = openAfterDismiss { openAfterDismiss = nil; openRecording?(id) }
            }) { item in
                NavigationStack {
                    SourceExcerptView(source: item.source, archive: archive, playback: playback,
                                      openRecording: openRecording == nil ? nil : { id in openAfterDismiss = id; selected = nil })
                }
            }
            .alert("链接不可用", isPresented: $unavailable) {
                Button("好", role: .cancel) { }
            } message: {
                Text("这条链接无法打开，引用可能无效或来源已变化。请重新查证来源。")
            }
    }
}

/// A manual recording mark opens its matching spans; it is not an assistant bibliography.
struct RecordingMarkSourceLinksView: View {
    let sources: [SourceReference]
    let archive: ArchiveStore
    let playback: AudioPlaybackController
    @State private var selected: SelectedSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sources.enumerated()), id: \.element.citationURL) { index, source in
                Button {
                    selected = SelectedSource(source: source)
                } label: {
                    Label("查看标记附近的转写 \(index + 1)", systemImage: "text.quote")
                        .phoneText(.navigation)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
            }
        }
        .sheet(item: $selected) { item in
            NavigationStack { SourceExcerptView(source: item.source, archive: archive, playback: playback) }
        }
    }
}

private struct SelectedSource: Identifiable {
    let source: SourceReference
    var id: String { "\(source.sessionID)/\(source.spanID)/\(source.generation)/\(source.transcriptVersion)" }
}

private struct SourceExcerptView: View {
    let source: SourceReference
    let archive: ArchiveStore
    let playback: AudioPlaybackController
    var openRecording: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var failure: String?
    @State private var playbackUnavailable: String?
    @State private var checkingAudio = true
    @State private var recordedAt: Date?
    @State private var rangeStart: Date?
    @State private var rangeEnd: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let text {
                    if let recordedAt {
                        Text(RecordingDatePresentation.title(recordedAt)).phoneText(.title)
                    }
                    if let rangeStart {
                        Text(rangeStart.formatted(.dateTime.hour().minute().second()) +
                             (rangeEnd.map { " – " + $0.formatted(.dateTime.hour().minute().second()) } ?? ""))
                            .phoneText(.metadata).monospacedDigit().foregroundStyle(MoMoPalette.muted)
                    }
                    Text(text).phoneText(.transcript).textSelection(.enabled)
                    AudioPlayerCard(playback: playback, target: .transcript(source),
                                    playLabel: String(localized: "回放这段原音"), actionIdentifier: "source.playback",
                                    unavailableReason: playbackUnavailable, failureIdentifier: "source.audioUnavailable",
                                    disabled: checkingAudio)
                    Text("只播放这段引用，结束后停在片段末尾。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    if let openRecording {
                        Button { openRecording(source.sessionID) } label: {
                            HStack {
                                Text("打开完整录音").phoneText(.body)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(MoMoPalette.muted)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("source.openRecording")
                    }
                }
                if let failure { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .overlay {
            if text == nil, failure == nil {
                ProgressView("读取原文")
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("source.loading")
                    .allowsHitTesting(false)
            }
        }
        .phonePageSurface()
        .navigationTitle("原文")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task {
            do {
                try await archive.validateSources([source])
                let document = try await archive.readTranscript(sessionID: source.sessionID)
                guard document.generation == source.generation,
                      let span = document.spans.first(where: { $0.id == source.spanID }) else { throw ArchiveError.staleSource }
                try await archive.validateSources([source])
                try Task.checkCancellation()
                text = span.text
                recordedAt = try await archive.recordingSummary(sessionID: source.sessionID).recordedAt
                rangeStart = try await archive.transcriptLocations(document: document)[source.spanID]?.recordedAt
                // Preflight this exact span rather than disabling every span in a partially expired recording.
                do {
                    let parts = try await archive.acquireAudioTimeline(source: source)
                    let end = parts.last.map { part in
                        part.lease.manifest.wallClockAnchor.addingTimeInterval(Double(part.frames.end) / part.lease.manifest.timebaseHz)
                    }
                    for part in parts { await archive.releaseAudioLease(id: part.lease.id) }
                    try Task.checkCancellation()
                    rangeEnd = end
                    playbackUnavailable = parts.isEmpty ? String(localized: "这段原音尚未收到，转录文字仍可阅读。") : nil
                } catch is CancellationError { return }
                catch { playbackUnavailable = await AudioPlaybackFailure.message(for: error, source: source, archive: archive) }
                checkingAudio = false
            } catch is CancellationError {
                // The dismissed or replaced excerpt must not publish its result.
            } catch {
                guard !Task.isCancelled else { return }
                text = nil
                switch error {
                case ArchiveError.staleSource, ArchiveError.sessionDeleted, ArchiveError.missingTranscript, ArchiveError.projectionConflict:
                    failure = String(localized: "原文已修改或删除，这条引用不再可用。")
                default:
                    failure = String(localized: "暂时无法读取原文，请稍后重试。")
                }
            }
        }
    }
}

enum AudioPlaybackFailure {
    static func message(for error: any Error, source: SourceReference, archive: ArchiveStore) async -> String {
        switch error {
        case ArchiveError.staleSource, ArchiveError.sessionDeleted, ArchiveError.missingTranscript, ArchiveError.projectionConflict:
            return String(localized: "原文已修改或删除，这条引用不再可用。")
        case ArchiveError.missingRecording:
            do {
                let state = try await archive.recordingSummary(sessionID: source.sessionID).audioState
                switch state {
                case .expired, .partiallyExpired:
                    return String(localized: "这段原音已按保留设置清理，转录文字仍可阅读。")
                case .expiryPending:
                    return String(localized: "这段原音正在按保留设置清理，转录文字仍可阅读。")
                case .missingUnexpected:
                    return String(localized: "原音文件意外缺失或校验失败，请到转录资料检查。")
                case .unavailable:
                    return String(localized: "这段原音尚未收到。")
                case .available:
                    return String(localized: "这段原音暂时不可用，请到转录资料检查。")
                }
            } catch {
                return String(localized: "暂时无法检查原音状态，请稍后重试。")
            }
        default:
            return String(localized: "原音暂时无法播放，请稍后重试。")
        }
    }
}
