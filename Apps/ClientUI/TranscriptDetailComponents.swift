import SwiftUI

/// Presentation shared by the phone's local recording and the Mac's remote source.
struct TranscriptAudioCardSurface<Playback: View, Times: View>: View {
    @ViewBuilder let playback: () -> Playback
    @ViewBuilder let times: () -> Times

    var body: some View {
        VStack(spacing: 0) {
            playback()
            HStack(spacing: 16) {
                Color.clear.frame(width: 52, height: 1).accessibilityHidden(true)
                times()
            }.padding(.top, -4)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 88, alignment: .top)
        #if os(iOS)
        .recapCardSurface(cornerRadius: 22)
        #else
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        #endif
        .accessibilityElement(children: .contain)
    }
}

struct TranscriptUnavailableAudioCard: View {
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptAudioCardSurface {
                HStack(spacing: 16) {
                    PlaybackToggleButton(playing: false, loading: false, label: reason, size: 52,
                                         identifier: "transcript.recording.play") {}.disabled(true)
                    PlaybackEmptyWaveform().frame(height: 52)
                }
            } times: { PlaybackTimes(position: 0, duration: nil) }
            Text(reason).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
        }
    }
}

struct TranscriptDetailDateHeader: View {
    let date: String
    let time: String?
    var duration: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(date).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            if let time { Text(time).phoneText(.heading).monospacedDigit() }
            if let duration { Text(duration).phoneText(.metadata).foregroundStyle(MoMoPalette.muted) }
        }
    }
}

struct TranscriptParagraphText: View, Equatable {
    let text: String
    let accessibilityID: String
    var body: some View {
        #if os(macOS)
        MarkdownReadingView(markdown: text, accessibilityID: accessibilityID, handwriting: false, plainTextOnly: true)
            .equatable()
        #else
        Text(text).phoneText(.transcript).textSelection(.enabled).accessibilityIdentifier(accessibilityID)
        #endif
    }
}

struct TranscriptDiscussAction: View {
    let title: String
    let enabled: Bool
    var backgroundColor: Color = MoMoPalette.canvas
    let action: () -> Void
    #if os(macOS)
    @State private var hovered = false
    #endif
    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    #if os(macOS)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .accessibilityHidden(true)
                    #endif
                    Text(LocalizedStringKey(title)).phoneText(.body)
                }
                #if os(macOS)
                .frame(maxWidth: .infinity, minHeight: 42)
                #else
                .frame(maxWidth: .infinity, minHeight: 52)
                #endif
                .contentShape(Capsule())
            }
            .buttonStyle(MoMoPressableButtonStyle(scale: 0.985))
            .foregroundStyle(MoMoPalette.canvas)
            #if os(macOS)
            .background(MoMoPalette.ink.opacity(enabled ? (hovered ? 0.88 : 1.0) : 0.3), in: Capsule())
            .onHover { hovered = $0 }
            #else
            .background(MoMoPalette.ink, in: Capsule())
            #endif
            .disabled(!enabled)
            .accessibilityIdentifier("transcript.discuss")
        }
        .padding(.horizontal, 24)
        #if os(macOS)
        .padding(.top, 8).padding(.bottom, 16)
        #else
        .padding(.vertical, 12)
        #endif
        .background(backgroundColor, ignoresSafeAreaEdges: [])
    }
}

struct TimelineSummaryView: View {
    let text: String
    var metadata: String? = nil
    var body: some View {
        #if os(iOS)
        let recap = TranscriptRecapContent.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.page")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted)
                    .accessibilityHidden(true)
                Text(metadata ?? String(localized: "AI 总结"))
                    .phoneText(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
                Spacer(minLength: 0)
            }
            if !recap.isEmpty {
                TranscriptRecapBody(content: recap, compact: false, accessibilityID: "timeline.summary.content")
                    .equatable()
                    .textSelection(.enabled)
            } else {
                MarkdownReadingView(markdown: text, accessibilityID: "timeline.summary.content").equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .recapCardSurface(cornerRadius: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.summary")
        #else
        VStack(alignment: .leading, spacing: 12) {
            Label("总结", systemImage: "text.alignleft").phoneText(.menu).fontWeight(.semibold)
            MarkdownReadingView(markdown: text, accessibilityID: "timeline.summary.content").equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.summary")
        #endif
    }
}

struct PlaybackToggleButton: View {
    let playing: Bool
    let loading: Bool
    let label: String
    let size: CGFloat
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if loading { ProgressView().tint(MoMoPalette.paper) }
                else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.38)) }
            }
            .foregroundStyle(MoMoPalette.paper).frame(width: size, height: size)
            .background(MoMoPalette.ink, in: Circle())
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

struct PlaybackTimes: View {
    let position: Double
    let duration: Double?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(PlaybackTime.text(position))
            Spacer(minLength: 8)
            Text(PlaybackTime.text(duration))
        }
        .phoneText(.caption).monospacedDigit().foregroundStyle(MoMoPalette.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlaybackTime.text(position))，共 \(PlaybackTime.text(duration))")
    }
}

enum PlaybackTime {
    static func text(_ time: Double?) -> String {
        guard let time, time.isFinite, time >= 0, time < Double(Int.max) else { return "--:--" }
        let seconds = Int(time.rounded(.down))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}


struct PlaybackEmptyWaveform: View {
    var body: some View {
            // A quiet ruler holds the layout while derived peaks arrive; it is not fabricated audio.
            Canvas { context, size in
                for x in stride(from: CGFloat(1), through: max(1, size.width - 1), by: 4) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: size.height / 2 - 0.8, width: 1.6, height: 1.6)),
                                 with: .color(MoMoPalette.muted.opacity(0.25)))
                }
            }
            .accessibilityLabel("录音波形")
    }
}
