import SwiftUI

struct SpeechDetectionSettingsView: View {
    let settings: PhoneSpeechSettings
    @State private var draftThreshold: Double?
    @State private var isDragging = false

    private var displayedThreshold: Double {
        draftThreshold ?? settings.vadThreshold
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("语音检测阈值").phoneText(.body)
                        Spacer()
                        Text(displayedThreshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                    Slider(
                        value: Binding(
                            get: { displayedThreshold },
                            set: { next in
                                if isDragging { draftThreshold = next }
                                else { draftThreshold = nil; settings.selectVADThreshold(next) }
                            }
                        ),
                        in: PhoneSpeechSettings.vadThresholdRange,
                        step: 0.05
                    ) {
                        Text("语音检测阈值")
                    } onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let pending = draftThreshold {
                            draftThreshold = nil
                            settings.selectVADThreshold(pending)
                        }
                    }
                    .accessibilityValue(String(format: "%.2f", displayedThreshold))
                    .accessibilityIdentifier("settings.speech.threshold")
                    Text("越低越容易识别轻声，也更容易混入噪声。默认 0.25。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    Button("恢复默认") {
                        draftThreshold = nil
                        settings.selectVADThreshold(PhoneSpeechSettings.defaultVADThreshold)
                    }
                        .buttonStyle(PhoneActionButtonStyle())
                        .disabled(displayedThreshold == PhoneSpeechSettings.defaultVADThreshold)
                        .accessibilityIdentifier("settings.speech.threshold.reset")
                }
                .padding(18).background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                Text("下一批分析生效，已有文字保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if let failure = settings.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("语音检测")
        .navigationBarTitleDisplayMode(.inline)
    }
}
