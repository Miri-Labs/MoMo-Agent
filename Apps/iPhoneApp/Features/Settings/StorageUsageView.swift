import SwiftUI
import MoMoArchive

enum LocalSpeechModelStatus {
    case unavailable(String)
    case awaitingValidation
    case preparing
    case preparationDeferred
    case ready

    var title: String {
        switch self {
        case .unavailable(let reason): reason
        case .awaitingValidation: String(localized: "模型文件已配置，将在设备条件允许时准备。")
        case .preparing: String(localized: "正在后台准备本地模型，录音和界面可正常使用。")
        case .preparationDeferred: String(localized: "本地模型准备暂未完成，录音已保留，转写时会重试。")
        case .ready: String(localized: "模型已校验并加载，可以离线转写。")
        }
    }
}

struct StorageUsageView: View {
    let archive: ArchiveStore
    let modelDirectory: URL?
    let modelStatus: LocalSpeechModelStatus
    @State private var usage: ArchiveStorageUsage?
    @State private var failure: String?
    @State private var refreshID = UUID()
    @State private var policy: AudioRetentionPolicy?
    @State private var savedLimit: Int64?

    var body: some View {
        Form {
            Section {
                if let policy {
                    PhoneSettingsValueRow(title: String(localized: "原音自动保留"), value: Text(policy.title))
                        .accessibilityIdentifier("storage.retention.current")
                }
                if let savedLimit {
                    PhoneSettingsValueRow(title: String(localized: "原音存储上限"), value: Text(savedLimit.formatted(.byteCount(style: .file))))
                        .accessibilityIdentifier("storage.limit.current")
                }
                Text("原音自动管理，转录文字保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                Text("未转录、未同步确认或正在使用的原音继续保留，可能暂时超过期限或上限。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }.listRowBackground(MoMoPalette.surface)
            if let usage {
                if let available = usage.availableBytes, available == 0 {
                    Section {
                        Text("手机空间不足").phoneText(.title)
                        Text("当前没有可用空间，新的接收或转写可能无法完成。已有录音与转录仍然保留。")
                            .phoneText(.body).foregroundStyle(MoMoPalette.muted)
                    }.listRowBackground(MoMoPalette.canvas)
                }
                Section {
                    sizeRow(String(localized: "原音"), bytes: usage.audioBytes, id: "storage.audio")
                    sizeRow(String(localized: "文字资料"), bytes: usage.textBytes, id: "storage.text")
                    sizeRow(String(localized: "模型文件与下载"), bytes: usage.modelBytes, id: "storage.models")
                    sizeRow(String(localized: "录音与转录数据库"), bytes: usage.databaseBytes, id: "storage.database")
                    sizeRow(String(localized: "模型运行缓存"), bytes: usage.modelCacheBytes, id: "storage.modelCache")
                    sizeRow(String(localized: "聊天、索引与其他资料"), bytes: usage.otherArchiveBytes, id: "storage.other")
                    sizeRow(String(localized: "临时资料"), bytes: usage.temporaryBytes, id: "storage.temporary")
                    sizeRow(String(localized: "已统计合计"), bytes: usage.totalBytes, id: "storage.total")
                } header: { Text("本机文件").phoneText(.metadata).foregroundStyle(MoMoPalette.muted) } footer: {
                    Text("按文件大小统计，不含 App。模型含未完成下载；压缩与共享空间可能使实际占用不同。刷新可更新统计。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(MoMoPalette.surface)
                Section {
                    if let available = usage.availableBytes { sizeRow(String(localized: "当前可用"), bytes: available, id: "storage.available") }
                    else { PhoneSettingsValueRow(title: String(localized: "当前可用"), value: Text("系统未提供")) }
                    PhoneSettingsValueRow(title: String(localized: "统计时间"), value: Text(usage.measuredAt, format: .dateTime.hour().minute().second()))
                    if usage.skippedSymbolicLinks > 0 {
                        Text("跳过 \(usage.skippedSymbolicLinks) 个文件链接，未读取链接指向的外部内容。")
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                } header: {
                    Text("设备空间").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                .listRowBackground(MoMoPalette.surface)
            } else if failure == nil {
                ProgressView("正在统计文件…")
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .listRowBackground(MoMoPalette.surface)
            }
            if let failure {
                Section { Text(failure).foregroundStyle(MoMoPalette.failure).phoneText(.metadata) }
                    .listRowBackground(MoMoPalette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .phonePageSurface()
        .navigationTitle("储存空间").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .accessibilityIdentifier("storage.refresh")
            }
        }
        .task(id: refreshID) {
            failure = nil
            do {
                let currentPolicy = try await archive.audioRetentionPolicy()
                let currentLimit = try await archive.storageLimitBytes()
                let snapshot = try await archive.storageUsage(modelDirectory: modelDirectory)
                try Task.checkCancellation()
                policy = currentPolicy
                savedLimit = currentLimit
                usage = snapshot
            } catch is CancellationError {
                // A newer refresh or leaving the page replaces this measurement.
            } catch { failure = String(localized: "无法完成容量统计，请刷新重试：\(error.localizedDescription)") }
        }
    }

    private func sizeRow(_ title: String, bytes: Int64, id: String) -> some View {
        PhoneSettingsValueRow(title: title, value: Text(bytes.formatted(.byteCount(style: .file))))
            .accessibilityIdentifier(id)
    }
}
