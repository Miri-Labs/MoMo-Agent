import SwiftUI

struct ChatVoiceInputView: View {
    let voice: ChatVoiceInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: voice.cancel) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("取消语音输入")
            .accessibilityIdentifier("assistant.voice.cancel")
            VStack(alignment: .leading, spacing: 6) {
                if voice.phase == .recording {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("正在听…").phoneText(.metadata)
                        Spacer(minLength: 0)
                        Text(verbatim: String(format: "%d:%02d", voice.seconds / 60, voice.seconds % 60))
                            .monospacedDigit().phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    }
                    VoiceInputWaveform(levels: voice.levels)
                        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: voice.levels)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(voice.phase == .requesting ? String(localized: "正在准备麦克风…") : String(localized: "正在转成文字…"))
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            if voice.phase == .recording {
                Button(action: voice.finish) {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MoMoPalette.canvas)
                        .frame(width: 32, height: 32).background(MoMoPalette.ink, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("完成语音输入")
                .accessibilityIdentifier("assistant.voice.finish")
            }
        }
        .padding(.horizontal, 4).frame(minHeight: 88)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.voice.panel")
    }
}

private struct VoiceInputWaveform: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let step = geometry.size.width / CGFloat(levels.count)
                for (index, level) in levels.enumerated() {
                    let height = max(3, CGFloat(level) * geometry.size.height)
                    let x = (CGFloat(index) + 0.5) * step
                    path.move(to: CGPoint(x: x, y: (geometry.size.height - height) / 2))
                    path.addLine(to: CGPoint(x: x, y: (geometry.size.height + height) / 2))
                }
            }
            .stroke(MoMoPalette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(height: 24).accessibilityHidden(true)
    }
}
