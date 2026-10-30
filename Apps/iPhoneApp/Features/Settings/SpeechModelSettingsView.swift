import SwiftUI
import MoMoSpeech

struct SpeechModelSettingsView: View {
    let settings: PhoneSpeechModelSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modelCard(.senseVoice, subtitle: "默认 · 速度快，适合持续转录") {
                    if settings.choice != .senseVoice {
                        Button("使用 SenseVoice") { settings.select(.senseVoice) }
                            .disabled(busy)
                    }
                }
                modelCard(.funASRNano, subtitle: "实验性") {
                    Text("离线识别中文及方言、英文、日文，耗时与耗电可能更高。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    if let catalog = settings.catalog {
                        Text("下载：\(ByteCountFormatter.string(fromByteCount: catalog.downloadBytes, countStyle: .file))")
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                    if settings.downloading {
                        if let progress = settings.progress {
                            ProgressView(value: Double(progress.receivedBytes), total: Double(progress.totalBytes))
                            Text(progress.validating ? "正在校验模型…" : "正在下载…")
                                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        } else { ProgressView("正在准备下载…") }
                        if !settings.switching { Button("暂停下载") { settings.pause() } }
                    } else if settings.installed {
                        if settings.choice != .funASRNano {
                            Button("使用 FunASR Nano") { settings.select(.funASRNano) }.disabled(busy)
                            Button("删除下载", role: .destructive) { settings.removeDownload() }.disabled(busy)
                        }
                    } else {
                        Button(settings.progress == nil ? "下载并启用" : "继续下载并启用") { settings.downloadAndSelect() }
                            .disabled(busy || settings.catalog == nil)
                    }
                }
                if settings.switching { ProgressView("正在切换模型…") }
                else if settings.checking { ProgressView("正在检查模型…") }
                if let failure = settings.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(.red)
                }
                Text("当前片段完成后切换，已有转录保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("转录模型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refresh() }
    }

    private var busy: Bool { settings.downloading || settings.switching || settings.checking }

    private func modelCard<Content: View>(_ model: SpeechModelChoice, subtitle: LocalizedStringKey,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.title).phoneText(.body)
                Spacer()
                if settings.choice == model {
                    Label("使用中", systemImage: "checkmark.circle.fill").phoneText(.metadata)
                }
            }
            Text(subtitle).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            content().buttonStyle(PhoneActionButtonStyle())
        }
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("settings.speech.model.\(model.rawValue)")
    }
}

extension SpeechModelChoice {
    var title: String {
        switch self {
        case .senseVoice: "SenseVoice"
        case .funASRNano: "FunASR Nano"
        }
    }
}
