import SwiftUI
import MoMoArchive

struct TranscriptionBatchSection: View {
    let batches: [TranscriptionBatch]

    var body: some View {
        Section {
            ForEach(batches) { batch in
                VStack(alignment: .leading, spacing: 8) {
                    Text(title(batch)).phoneText(.body)
                    ProgressView(value: batch.completedDuration, total: max(1, batch.totalDuration))
                        .accessibilityLabel("本次转写进度")
                    Text("已处理 \(duration(batch.completedDuration)) / \(duration(batch.totalDuration))")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    if batch.removedDuration > 0 {
                        Text("其中 \(duration(batch.removedDuration)) 原音已删除，未计入已处理时长。")
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                }
            }
        } header: {
            Text("本次转写").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
        }
        .listRowBackground(MoMoPalette.surface)
        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
    }

    private func title(_ batch: TranscriptionBatch) -> String {
        if batch.endReason == .systemEndedUnknown { return String(localized: "上次处理进度已保存，将自动继续") }
        return switch batch.state {
        case .ready: String(localized: "已保存本次待处理音频")
        case .running: String(localized: "正在处理本次音频")
        case .paused: String(localized: "本次转写等待自动继续")
        case .completed: String(localized: "本次转写已完成")
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
