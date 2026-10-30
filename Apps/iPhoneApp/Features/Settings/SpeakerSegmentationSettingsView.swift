import SwiftUI
import MoMoSpeech

struct SpeakerSegmentationSettingsView: View {
    let settings: PhoneSpeechSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择多人对话的切分模型；声纹识别统一使用高精度中文模型。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                VStack(spacing: 0) {
                    ForEach(Array(SpeakerSegmentationModel.allCases.enumerated()), id: \.element) { index, model in
                        if index > 0 { Divider().padding(.leading, 18) }
                        Button {
                            settings.selectSpeakerSegmentationModel(model)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.title).phoneText(.body)
                                    Text(model.subtitle).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                                }
                                Spacer(minLength: 12)
                                if settings.speakerSegmentationModel == model {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(MoMoPalette.ink)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(settings.speakerSegmentationModel == model ? .isSelected : [])
                        .accessibilityIdentifier("settings.speech.segmentation.\(model.rawValue)")
                    }
                }
                .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                Text("用于新转录切分，已确认与学习的声纹继续通用。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("说话人分段")
        .navigationBarTitleDisplayMode(.inline)
    }
}
