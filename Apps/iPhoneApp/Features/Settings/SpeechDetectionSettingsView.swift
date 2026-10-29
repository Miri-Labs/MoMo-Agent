import SwiftUI

struct SpeechDetectionSettingsView: View {
    let settings: PhoneSpeechSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("语音检测阈值").phoneText(.body)
                        Spacer()
                        Text(settings.vadThreshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                    Slider(value: Binding(get: { settings.vadThreshold }, set: { settings.selectVADThreshold($0) }),
                           in: PhoneSpeechSettings.vadThresholdRange, step: 0.05) {
                        Text("语音检测阈值")
                    }
                    .accessibilityValue(String(format: "%.2f", settings.vadThreshold))
                    .accessibilityIdentifier("settings.speech.threshold")
                    Text("越低越容易识别轻声，也更容易混入噪声。默认 0.25。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    Button("恢复默认") { settings.selectVADThreshold(PhoneSpeechSettings.defaultVADThreshold) }
                        .buttonStyle(PhoneActionButtonStyle())
                        .disabled(settings.vadThreshold == PhoneSpeechSettings.defaultVADThreshold)
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
