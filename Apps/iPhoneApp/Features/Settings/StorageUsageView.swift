import SwiftUI
import MoMoArchive

struct StorageUsageView: View {
    let archive: ArchiveStore
    @State private var usage: ArchiveStorageUsage?
    @State private var failure: String?
    @State private var refreshID = UUID()
    @State private var policy: AudioRetentionPolicy?
    @State private var savedLimit: Int64?

    var body: some View {
        Form {
            Section {
                PhoneSettingsValueRow(title: String(localized: "转录计算引擎"), value: Text("Mac Core ML（本机 0 占用）"))
                if let policy {
                    PhoneSettingsValueRow(title: String(localized: "手机原音缓存保留"), value: Text(policy.title))
                        .accessibilityIdentifier("storage.retention.current")
                }
                if let savedLimit {
                    PhoneSettingsValueRow(title: String(localized: "原音缓存上限"), value: Text(savedLimit.formatted(.byteCount(style: .file))))
                        .accessibilityIdentifier("storage.limit.current")
                }
                Text("尚未上传到 Mac 的原音会被自动保护，不会提前清理；上传确认后按保留策略自动回收空间，转录文字永久保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }.listRowBackground(MoMoPalette.surface)
            if let usage {
                if let available = usage.availableBytes, available == 0 {
                    Section {
                        Text("手机空间不足").phoneText(.title)
                        Text("当前没有可用空间，新的录音接收可能无法完成。已有录音与转录仍然保留。")
                            .phoneText(.body).foregroundStyle(MoMoPalette.muted)
                    }.listRowBackground(MoMoPalette.canvas)
                }
                Section {
                    sizeRow(String(localized: "原音缓存"), bytes: usage.audioBytes, id: "storage.audio")
                    sizeRow(String(localized: "文字资料"), bytes: usage.textBytes, id: "storage.text")
                    sizeRow(String(localized: "录音与转录数据库"), bytes: usage.databaseBytes, id: "storage.database")
                    sizeRow(String(localized: "聊天、索引与其他资料"), bytes: usage.otherArchiveBytes, id: "storage.other")
                    sizeRow(String(localized: "临时资料"), bytes: usage.temporaryBytes, id: "storage.temporary")
                    sizeRow(String(localized: "已统计合计"), bytes: usage.totalBytes, id: "storage.total")
                } header: { Text("本机文件").phoneText(.metadata).foregroundStyle(MoMoPalette.muted) } footer: {
                    Text("按文件大小统计，不含 App 本身；语音模型运行在 Mac 端，不占用 iPhone 存储空间。")
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
                let snapshot = try await archive.storageUsage(modelDirectory: nil)
                try Task.checkCancellation()
                policy = currentPolicy
                savedLimit = currentLimit
                usage = snapshot
            } catch is CancellationError {
            } catch { failure = String(localized: "无法完成容量统计，请刷新重试：\(error.localizedDescription)") }
        }
    }

    private func sizeRow(_ title: String, bytes: Int64, id: String) -> some View {
        PhoneSettingsValueRow(title: title, value: Text(bytes.formatted(.byteCount(style: .file))))
            .accessibilityIdentifier(id)
    }
}
