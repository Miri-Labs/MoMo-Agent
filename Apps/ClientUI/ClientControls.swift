import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient
#if os(macOS)
import AppKit
#else
import MoMoSpeech
import PhotosUI
import UIKit
#endif

struct ClientPrimaryButton: ButtonStyle {
    var isLoading = false
    @Environment(\.isEnabled) private var enabled
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
                    #if os(macOS)
                    .environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
                    #else
                    .tint(MoMoPalette.canvas)
                    #endif
                    .accessibilityHidden(true)
            }
            configuration.label
        }.phoneText(.body).frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(MoMoPalette.canvas)
            .background(MoMoPalette.ink.opacity(isLoading ? 1 : enabled ? (configuration.isPressed ? 0.8 : 1) : 0.3), in: Capsule())
            .contentShape(Capsule())
    }
}

struct ClientComposer: View {
    @Binding var text: String
    var store: RemoteTaskStore? = nil
    var inputID = "remote.input"
    var sendID = "remote.send"
    var prompt: LocalizedStringKey = "发消息给 MoMo"
    var onCompose: () -> Void = {}
    var onPreviewAttachment: ((AgentAttachment) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    #if !os(macOS)
    var speech: SpeechEngine? = nil
    var stopPlayback: () async -> Void = {}
    var voiceInputEnabled = true
    #endif
    let send: () -> Void
    @FocusState private var focused: Bool
    @State private var showingFiles = false
    @State private var importingAttachments = false
    #if !os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = ChatVoiceInput()
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var cameraFailure: ChatCameraFailure?
    @State private var cameraRequest: Task<Void, Never>?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    #endif
    private var attachments: [AgentAttachment] { store?.draftAttachments ?? [] }
    private var voiceIsActive: Bool {
        #if os(macOS)
        false
        #else
        voice.isActive
        #endif
    }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !importingAttachments && !voiceIsActive
    }
    var body: some View {
        composerBody
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: ClientAttachmentImporter.allowedTypes, allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    guard urls.count + attachments.count <= 4 else {
                        onError?(String(localized: "一次最多添加 4 个附件。"))
                        return
                    }
                    importingAttachments = true
                    Task {
                        defer { importingAttachments = false }
                        do {
                            let values = try await Task.detached(priority: .userInitiated) { try urls.map(ClientAttachmentImporter.file) }.value
                            try store?.addAttachments(values)
                        } catch { onError?(error.localizedDescription) }
                    }
                } catch { onError?(error.localizedDescription) }
            }
            #if !os(macOS)
            .photosPicker(isPresented: $showingPhotos, selection: $selectedPhotos,
                maxSelectionCount: max(1, 4 - attachments.count), matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                importingAttachments = true
                Task {
                    defer { importingAttachments = false }
                    do {
                        var values: [AgentAttachment] = []
                        for item in items {
                            guard let bytes = try await item.loadTransferable(type: Data.self) else { throw ClientAttachmentImportError.unreadable }
                            let value = try await Task.detached(priority: .userInitiated) { try ClientAttachmentImporter.image(bytes) }.value
                            values.append(value)
                        }
                        try store?.addAttachments(values)
                    } catch { onError?(error.localizedDescription) }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                ChatCameraPicker(completion: receiveCameraPhoto).ignoresSafeArea()
            }
            .alert("无法使用相机", isPresented: Binding(get: { cameraFailure != nil }, set: { if !$0 { cameraFailure = nil } }), presenting: cameraFailure) { failure in
                if failure == .denied {
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { failure in Text(failure.message) }
            .onChange(of: store.map(ObjectIdentifier.init)) { voice.cancel() }
            .onChange(of: voiceInputEnabled) { if !voiceInputEnabled { voice.cancel() } }
            .onChange(of: scenePhase) { if scenePhase == .background { voice.cancel() } }
            .onDisappear { cameraRequest?.cancel(); voice.cancel() }
            #endif
    }

    @ViewBuilder private var composerBody: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ClientAttachmentStrip(attachments: attachments, remove: { store?.removeAttachment($0) },
                                      preview: { onPreviewAttachment?($0) })
            }
            if importingAttachments {
                Text("正在读取附件…").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            inputField
                .onKeyPress(.return, phases: .down) { key in
                    guard key.modifiers.contains(.shift),
                          let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                          !editor.hasMarkedText() else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                .onSubmit { if canSend { send() } }
                .padding(.horizontal, 18).padding(.top, attachments.isEmpty && !importingAttachments ? 18 : 6)
            HStack {
                if store != nil { attachmentButton }
                Spacer()
                sendControl
            }.padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(MoMoPalette.line, lineWidth: 1) }
        .tint(MoMoPalette.ink)
        #else
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ClientAttachmentStrip(attachments: attachments, remove: { store?.removeAttachment($0) },
                                      preview: { onPreviewAttachment?($0) })
            }
            if importingAttachments {
                Text("正在读取附件…").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.top, 4)
            }
            if voice.isActive {
                ChatVoiceInputView(voice: voice)
                    .buttonStyle(.plain)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    if store != nil { attachmentButton }
                    inputField.padding(.leading, store == nil ? 16 : 2).padding(.vertical, 12)
                    voiceButton
                    sendControl
                }
            }
            if let failure = voice.failure {
                HStack(alignment: .top, spacing: 8) {
                    Text(failure).phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    if voice.permissionDenied {
                        Button("打开设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.phoneText(.caption)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("assistant.voice.failure")
            }
        }
        .padding(4)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 26))
        .tint(MoMoPalette.ink)
        #endif
    }

    @ViewBuilder private var attachmentButton: some View {
        #if os(macOS)
        Button {
            showingFiles = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
                .frame(width: 32, height: 32)
                .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(importingAttachments || attachments.count >= 4)
        .help("添加照片或文件")
        .accessibilityLabel("添加照片或文件")
        .accessibilityIdentifier("assistant.attachments")
        #else
        Menu {
            Button("拍照", systemImage: "camera") { openCamera() }
                .accessibilityIdentifier("assistant.attachments.camera")
            Button("照片图库", systemImage: "photo.on.rectangle") { focused = false; showingPhotos = true }
            Button("选择文件", systemImage: "doc") { focused = false; showingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
                .frame(width: 32, height: 32)
                .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(importingAttachments || cameraRequest != nil || attachments.count >= 4)
        .accessibilityLabel("拍照或添加照片和文件")
        .accessibilityIdentifier("assistant.attachments")
        #endif
    }

    #if !os(macOS)
    private var voiceButton: some View {
        Button {
            guard let speech else {
                voice.failure = ChatVoiceFailure.unavailable.localizedDescription
                return
            }
            focused = false
            onCompose()
            voice.start(recognize: { try await speech.dictate(samples: $0, attempt: $1) },
                        stopPlayback: stopPlayback) { result in
                text = text.isEmpty ? result : text + "\n" + result
                focused = true
            }
        } label: {
            Image(systemName: "mic").font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!voiceInputEnabled || importingAttachments || cameraRequest != nil)
        .accessibilityLabel("语音输入")
        .accessibilityIdentifier("assistant.voice.start")
    }

    private func openCamera() {
        guard cameraRequest == nil, !importingAttachments, attachments.count < 4 else { return }
        focused = false
        cameraRequest = Task {
            defer { cameraRequest = nil }
            let failure = await ChatCameraPicker.authorizationFailure()
            guard !Task.isCancelled else { return }
            if let failure { cameraFailure = failure }
            else { showingCamera = true }
        }
    }

    private func receiveCameraPhoto(_ result: Result<UIImage?, ChatAttachmentImportError>) {
        showingCamera = false
        do {
            guard let image = try result.get() else { return }
            importingAttachments = true
            Task {
                defer { importingAttachments = false }
                do {
                    let value = try await Task.detached(priority: .userInitiated) { try ChatAttachmentImporter.cameraImage(image) }.value
                    try store?.addAttachments([value])
                } catch { onError?(error.localizedDescription) }
            }
        } catch { onError?(error.localizedDescription) }
    }
    #endif

    private var inputField: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .phoneText(.body)
            .lineLimit(1...5).textFieldStyle(.plain).accessibilityIdentifier(inputID)
            .focused($focused)
            .onChange(of: focused) { if focused { onCompose() } }
            .onChange(of: text) { if focused { onCompose() } }
    }
    private var sendControl: some View {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).background(MoMoPalette.ink.opacity(canSend ? 1 : 0.12), in: Circle())
                    .foregroundStyle(canSend ? MoMoPalette.canvas : MoMoPalette.muted)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.buttonStyle(.plain)
                .disabled(!canSend).accessibilityLabel("发送给 MoMo").accessibilityIdentifier(sendID)
                #if os(macOS)
                .keyboardShortcut(.return, modifiers: .command)
                #endif
    }
}

struct ClientMemoryContent: View {
    let memory: ContextMemory
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(memory.status == "stale" ? "原文已改变，暂不作为当前记忆" : memory.basis == "hermes" ? (memory.kind == "user" ? "关于你" : "MoMo 的记忆") : memory.basis == "inferred" ? "模型推断" : "根据录音中的陈述", systemImage: memory.status == "stale" ? "clock.badge.exclamationmark" : "quote.bubble")
                .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            Text(memory.text)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).accessibilityIdentifier("remote.memoryText")
            ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                VStack(alignment: .leading, spacing: 6) {
                    Text(evidence.quote).phoneText(.metadata).textSelection(.enabled)
                    if let time = evidence.recordedAt { Text(Date(timeIntervalSince1970: time), format: .dateTime.month().day().hour().minute()).phoneText(.caption) }
                }.foregroundStyle(MoMoPalette.muted)
            }
        }.phoneText(.body)
    }
}
