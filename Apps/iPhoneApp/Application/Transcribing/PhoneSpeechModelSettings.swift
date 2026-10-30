import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import MoMoSpeech

@MainActor @Observable
final class PhoneSpeechModelSettings {
    static let selectionKey = "speech.recognitionModel"
    private(set) var choice: SpeechModelChoice
    private(set) var installed = false
    private(set) var checking = false
    private(set) var downloading = false
    private(set) var switching = false
    private(set) var progress: SpeechModelInstaller.Progress?
    private(set) var failure: String?
    let catalog: DownloadableSpeechModel?
    @ObservationIgnored private let speech: SpeechEngine?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installer: SpeechModelInstaller?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(speech: SpeechEngine?, directory: URL, defaults: UserDefaults = .standard) {
        self.speech = speech
        self.defaults = defaults
        choice = speech?.recognitionModel ?? .senseVoice
        do {
            let catalog = try DownloadableSpeechModel.funASRNano()
            let installer = try SpeechModelInstaller(catalog: catalog, directory: directory)
            self.catalog = catalog
            self.installer = installer
        } catch {
            catalog = nil
            installer = nil
            failure = String(localized: "模型下载信息不可用，请更新 App。")
        }
        if defaults.string(forKey: Self.selectionKey) == SpeechModelChoice.funASRNano.rawValue, choice != .funASRNano {
            failure = String(localized: "FunASR 文件未就绪，当前使用 SenseVoice。请重新下载后启用。")
        }
    }

    /// Startup only checks the small receipt. Weight validation runs later on the recognition queue.
    static func restoredDownload(at root: URL, defaults: UserDefaults = .standard) -> DownloadedSpeechModel? {
        guard defaults.string(forKey: selectionKey) == SpeechModelChoice.funASRNano.rawValue,
              defaults.string(forKey: PhoneSpeechSettings.languageKey) != SpeechLanguage.korean.rawValue,
              let catalog = try? DownloadableSpeechModel.funASRNano(),
              let revision = try? catalog.revision else { return nil }
        let directory = root.appendingPathComponent(revision)
        let receipt = directory.appendingPathComponent("complete.json")
        guard let size = try? receipt.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let bytes = try? Data(contentsOf: receipt),
              let saved = try? JSONDecoder().decode(DownloadableSpeechModel.self, from: bytes),
              saved == catalog else { return nil }
        for file in catalog.files {
            guard let values = try? directory.appendingPathComponent(file.path)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == file.byteCount else { return nil }
        }
        return DownloadedSpeechModel(directory: directory, catalog: catalog)
    }

    func refresh() async {
        guard !checking, !downloading, !switching, let installer else { return }
        checking = true
        defer { checking = false }
        do { installed = try await installer.installedDirectory() != nil }
        catch { installed = false; failure = Self.message(error) }
    }

    func downloadAndSelect() {
        guard !downloading, !switching, !checking, let installer, let catalog else { return }
        downloading = true
        failure = nil
        task = Task { [self] in
            #if canImport(UIKit)
            let grant = UIApplication.shared.beginBackgroundTask(withName: "Speech model download") { [weak self] in
                Task { @MainActor in self?.pause() }
            }
            #endif
            defer {
                #if canImport(UIKit)
                if grant != .invalid { UIApplication.shared.endBackgroundTask(grant) }
                #endif
                downloading = false
                task = nil
            }
            do {
                let directory = try await installer.install { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                try Task.checkCancellation()
                installed = true
                try await activate(DownloadedSpeechModel(directory: directory, catalog: catalog))
            } catch is CancellationError {
                // Completed ranges remain available to the next explicit download.
            } catch {
                if !Task.isCancelled { failure = Self.message(error) }
            }
        }
    }

    func pause() { task?.cancel() }

    func select(_ model: SpeechModelChoice) {
        guard !downloading, !checking, !switching, choice != model else { return }
        failure = nil
        switching = true
        task = Task { [self] in
            defer { switching = false; task = nil }
            do {
                if model == .senseVoice { try await activate(nil) }
                else if let installer, let catalog, let directory = try await installer.installedDirectory() {
                    try await activate(DownloadedSpeechModel(directory: directory, catalog: catalog))
                } else {
                    installed = false
                    failure = String(localized: "请先下载 FunASR 模型。")
                }
            } catch { failure = Self.message(error) }
        }
    }

    func removeDownload() {
        guard choice != .funASRNano, !downloading, !switching, !checking, let installer else { return }
        checking = true
        task = Task { [self] in
            defer { checking = false; task = nil }
            do {
                try await installer.remove()
                installed = false
                progress = nil
                failure = nil
            } catch { failure = Self.message(error) }
        }
    }

    private func activate(_ download: DownloadedSpeechModel?) async throws {
        guard let speech else { throw SpeechError.nativeInitialization }
        switching = true
        defer { switching = false }
        try await speech.selectRecognitionModel(download)
        choice = speech.recognitionModel
        defaults.set(choice.rawValue, forKey: Self.selectionKey)
    }

    private static func message(_ error: Error) -> String {
        if case SpeechModelInstallationError.insufficientSpace(let required) = error {
            return String(localized: "可用空间不足，下载还需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))。")
        }
        if case SpeechModelSelectionError.unsupportedLanguage = error {
            return String(localized: "FunASR 不支持韩语。请先将识别语言改为自动、中文、英文或日文。")
        }
        if case SpeechModelInstallationError.fileMismatch = error {
            return String(localized: "模型文件校验失败，请重试下载。")
        }
        if error is URLError {
            return String(localized: "下载中断。已下载的部分已保存，可以继续下载。")
        }
        return String(localized: "模型未能启用，请重试。当前模型保持不变。")
    }
}
