import SwiftUI
import MoMoAgentClient
import MoMoArchive

struct SpeakerFeedbackMenu: View {
    let speaker: String?
    let attribution: SpeakerAttribution?
    let source: SourceReference
    var additionalSources: [SourceReference] = []
    var initialPeople: [SpeakerProfile] = []
    let archive: ArchiveStore
    var enqueueFeedback: ((_ sources: [SourceReference], _ speakerNameHint: String?, _ feedback: SpeakerFeedback, _ scope: SpeakerFeedbackScope, _ optimisticSpeaker: String?, _ optimisticAttribution: SpeakerAttribution?) -> Void)? = nil
    let changed: () async -> Void
    @Environment(PhoneRemoteAgent.self) private var remoteAgent: PhoneRemoteAgent?
    @Environment(AudioUploadCoordinator.self) private var uploader: AudioUploadCoordinator?
    @State private var choosing = false

    private var displayName: String {
        guard let speaker, speaker != String(localized: "说话人未确定") else { return String(localized: "说话人") }
        return speaker
    }

    private var isOwnerDisplay: Bool {
        attribution?.isUser == true || speaker == "我" || speaker == String(localized: "我")
    }

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 4) {
                Text(displayName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.medium)).accessibilityHidden(true)
            }
            .phoneText(.caption)
            .foregroundStyle(isOwnerDisplay ? MoMoPalette.success : (attribution?.personID != nil ? MoMoPalette.ink : MoMoPalette.muted))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isOwnerDisplay ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.045), in: Capsule())
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("说话人"))
        .accessibilityValue(Text(displayName))
        .accessibilityIdentifier("transcript.speaker.\(source.spanID)")
        .sheet(isPresented: $choosing) {
            SpeakerPicker(
                archive: archive,
                remoteAgent: remoteAgent,
                uploader: uploader,
                sources: [source] + additionalSources,
                speaker: displayName,
                attribution: attribution,
                initialPeople: initialPeople,
                enqueueFeedback: enqueueFeedback,
                changed: changed
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SpeakerPicker: View {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent?
    let uploader: AudioUploadCoordinator?
    let sources: [SourceReference]
    let speaker: String
    let attribution: SpeakerAttribution?
    let initialPeople: [SpeakerProfile]
    let enqueueFeedback: ((_ sources: [SourceReference], _ speakerNameHint: String?, _ feedback: SpeakerFeedback, _ scope: SpeakerFeedbackScope, _ optimisticSpeaker: String?, _ optimisticAttribution: SpeakerAttribution?) -> Void)?
    let changed: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [SpeakerProfile]
    @State private var macProfiles: [VoiceprintProfile] = []
    @State private var wholeGroup: Bool
    @State private var enrollVoiceprint = true
    @State private var groupCount = 0
    @State private var name = ""
    @State private var naming = false
    @State private var search = ""
    @FocusState private var nameFocused: Bool
    @State private var loaded: Bool
    @State private var saving = false
    @State private var failure: String?

    private var macClient: AgentClient? { remoteAgent?.speechDataClient }

    init(
        archive: ArchiveStore,
        remoteAgent: PhoneRemoteAgent?,
        uploader: AudioUploadCoordinator?,
        sources: [SourceReference],
        speaker: String,
        attribution: SpeakerAttribution?,
        initialPeople: [SpeakerProfile],
        enqueueFeedback: ((_ sources: [SourceReference], _ speakerNameHint: String?, _ feedback: SpeakerFeedback, _ scope: SpeakerFeedbackScope, _ optimisticSpeaker: String?, _ optimisticAttribution: SpeakerAttribution?) -> Void)?,
        changed: @escaping () async -> Void
    ) {
        self.archive = archive
        self.remoteAgent = remoteAgent
        self.uploader = uploader
        self.sources = sources
        self.speaker = speaker
        self.attribution = attribution
        self.initialPeople = initialPeople
        self.enqueueFeedback = enqueueFeedback
        self.changed = changed
        _people = State(initialValue: initialPeople)
        _wholeGroup = State(initialValue: attribution?.confirmed != true)
        _loaded = State(initialValue: enqueueFeedback != nil || !initialPeople.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if macClient != nil {
                    Section {
                        Toggle("同时记住 TA 的声音（加入声纹名册）", isOn: $enrollVoiceprint)
                            .accessibilityIdentifier("speaker.enroll.toggle")
                    } footer: {
                        Text("开启后会提取这段清晰语音写入 Mac 声纹名册，后续和全部历史录音自动锁定该说话人。仅更正标注而不录入声纹可关闭。")
                    }
                }
                Section {
                    Button { chooseOwner() } label: {
                        profileRow(name: String(localized: "我"), selected: attribution?.isUser == true || speaker == "我")
                    }.accessibilityIdentifier("speaker.choose.owner")

                    if macClient != nil {
                        if macProfiles.count > 10 {
                            TextField("搜索人物", text: $search).accessibilityIdentifier("speaker.search")
                        }
                        ForEach(macProfiles.filter { !$0.isOwner && (search.isEmpty || $0.name.localizedStandardContains(search)) }) { person in
                            Button { chooseMacPerson(person) } label: {
                                profileRow(name: person.name, selected: speaker == person.name)
                            }.accessibilityIdentifier("speaker.choose.mac.\(person.id)")
                        }
                    } else {
                        if people.count > 10 {
                            TextField("搜索人物", text: $search).accessibilityIdentifier("speaker.search")
                        }
                        ForEach(people.filter { !$0.isUser && (search.isEmpty || $0.name.localizedStandardContains(search)) }) { person in
                            Button { correctLocal(.knownPerson(person.id)) } label: {
                                profileRow(name: person.name, selected: attribution?.personID == person.id)
                            }.accessibilityIdentifier("speaker.choose.\(person.id)")
                        }
                    }
                } header: { Text("这是谁") }
                if groupCount > sources.count || macClient != nil {
                    Section {
                        Picker("应用范围", selection: $wholeGroup) {
                            Text(groupCount > sources.count ? "这个说话人（\(groupCount) 段）" : "同场录音中该说话人").tag(true)
                            Text("仅这段").tag(false)
                        }.pickerStyle(.menu)
                    }
                }
                Section {
                    if naming {
                        TextField("姓名", text: $name).textContentType(.name)
                            .focused($nameFocused).submitLabel(.done)
                            .onAppear { nameFocused = true }
                            .onSubmit {
                                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty { chooseNewPerson(trimmed) }
                            }
                            .accessibilityIdentifier("speaker.new.name")
                    } else {
                        Button("添加人物", systemImage: "person.badge.plus") { naming = true }
                            .accessibilityIdentifier("speaker.new.add")
                    }
                }
                Section {
                    if macClient != nil, speaker != String(localized: "说话人"), !speaker.hasPrefix("说话人 ") {
                        Button("这不是\(speaker)", role: .destructive) { rejectMacMatch() }
                    } else if let personID = attribution?.personID {
                        Button("这不是\(speaker)", role: .destructive) { correctLocal(.notPerson(personID)) }
                    }
                    if attribution != nil, macClient == nil {
                        Button("撤销标记", systemImage: "arrow.uturn.backward") { correctLocal(.clear) }
                    }
                }
            }
            .buttonStyle(.automatic)
            .disabled(!loaded || saving)
            .tint(MoMoPalette.ink)
            .phoneSoftTopEdge()
            .navigationTitle("说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                if naming {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            chooseNewPerson(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(!loaded || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("speaker.new.save")
                    }
                }
            }
            .overlay { if (!loaded && failure == nil) || saving { ProgressView() } }
            .task {
                if let client = macClient {
                    macProfiles = (try? await client.voiceprintProfiles()) ?? []
                }
                do {
                    let latestPeople = try await archive.speakerProfiles()
                    people = latestPeople
                    loaded = true
                    let freshSources = (try? await archive.resolveCurrentSpeakerSources(sources)) ?? sources
                    let preview = try await archive.speakerFeedbackPreview(freshSources)
                    groupCount = preview.count
                } catch is CancellationError {
                    return
                } catch {
                    loaded = true
                }
            }
            .alert("声纹未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil; if !loaded { dismiss() } }
            } message: { Text(failure ?? "") }
        }
    }

    private func profileRow(name: String, selected: Bool) -> some View {
        HStack {
            Text(name).foregroundStyle(MoMoPalette.ink)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(MoMoPalette.ink).accessibilityLabel("当前说话人") }
        }.contentShape(Rectangle())
    }

    private func macSourceID() -> String? {
        guard let first = sources.first else { return nil }
        return "\(archive.libraryInstanceID.uuidString.lowercased())/\(first.sessionID.uuidString.lowercased())"
    }

    private func chooseOwner() {
        if let client = macClient, let sourceID = macSourceID() {
            let ownerProfile = macProfiles.first(where: \.isOwner)
            bindOnMac(
                client: client,
                sourceID: sourceID,
                profileID: ownerProfile?.id,
                targetName: ownerProfile?.name ?? "我",
                isOwner: true
            )
        } else {
            correctLocal(.owner)
        }
    }

    private func chooseMacPerson(_ person: VoiceprintProfile) {
        guard let client = macClient, let sourceID = macSourceID() else { return }
        bindOnMac(
            client: client,
            sourceID: sourceID,
            profileID: person.id,
            targetName: person.name,
            isOwner: person.isOwner
        )
    }

    private func chooseNewPerson(_ trimmed: String) {
        guard !trimmed.isEmpty else { return }
        if let client = macClient, let sourceID = macSourceID() {
            let existing = macProfiles.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
            bindOnMac(
                client: client,
                sourceID: sourceID,
                profileID: existing?.id,
                targetName: trimmed,
                isOwner: existing?.isOwner ?? false
            )
        } else {
            correctLocal(.person(trimmed))
        }
    }

    private func bindOnMac(
        client: AgentClient,
        sourceID: String,
        profileID: String?,
        targetName: String,
        isOwner: Bool
    ) {
        guard !saving else { return }
        nameFocused = false
        saving = true
        let spanIDs = sources.map { $0.spanID.uuidString.lowercased() }
        let scope = wholeGroup ? "cluster" : "selection"
        let enroll = enrollVoiceprint
        let notifyChanged = changed
        Task {
            do {
                _ = try await client.bindTranscriptSpeaker(
                    sourceID: sourceID,
                    spanIDs: spanIDs,
                    clusterKey: nil,
                    profileID: profileID,
                    targetName: targetName,
                    isOwner: isOwner,
                    enrollVoiceprint: enroll,
                    rematchHistory: true,
                    scope: scope
                )
                await uploader?.syncRemoteTranscriptsFromMac(force: true)
                saving = false
                dismiss()
                await notifyChanged()
            } catch {
                saving = false
                failure = error.localizedDescription
            }
        }
    }

    private func rejectMacMatch() {
        guard !saving, let client = macClient, let sourceID = macSourceID() else { return }
        saving = true
        let spanIDs = sources.map { $0.spanID.uuidString.lowercased() }
        let profileID = macProfiles.first(where: { $0.name == speaker || ($0.isOwner && speaker == "我") })?.id
        let notifyChanged = changed
        Task {
            do {
                _ = try await client.rejectSpeakerMatch(
                    sourceID: sourceID,
                    profileID: profileID,
                    speakerName: speaker,
                    spanIDs: spanIDs
                )
                await uploader?.syncRemoteTranscriptsFromMac(force: true)
                saving = false
                dismiss()
                await notifyChanged()
            } catch {
                saving = false
                failure = error.localizedDescription
            }
        }
    }

    private func validateAndProject(_ feedback: SpeakerFeedback) throws -> (SpeakerFeedback, String?, SpeakerAttribution?) {
        let clusterID = attribution?.clusterID ?? UUID()
        let canLearn = attribution?.canLearn ?? false
        switch feedback {
        case .owner:
            let ownerID = people.first(where: \.isUser)?.id ?? UUID()
            return (.owner, String(localized: "我"), SpeakerAttribution(clusterID: clusterID, personID: ownerID, isUser: true, confirmed: true, canLearn: canLearn))
        case .knownPerson(let id):
            guard let person = people.first(where: { $0.id == id }) else { throw VoiceprintError.missingPerson }
            return (.knownPerson(id), person.name, SpeakerAttribution(clusterID: clusterID, personID: id, isUser: person.isUser, confirmed: true, canLearn: canLearn))
        case .person(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VoiceprintError.invalidName
            }
            guard trimmed.caseInsensitiveCompare(String(localized: "我")) != .orderedSame,
                  !people.contains(where: { $0.isUser && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw VoiceprintError.duplicateName
            }
            let resolvedID = people.first(where: { !$0.isUser && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })?.id ?? UUID()
            return (.person(trimmed), trimmed, SpeakerAttribution(clusterID: clusterID, personID: resolvedID, isUser: false, confirmed: true, canLearn: canLearn))
        case .notOwner, .notPerson:
            let fallbackAttribution = attribution.map {
                SpeakerAttribution(clusterID: $0.clusterID, personID: nil, isUser: false, confirmed: false, canLearn: $0.canLearn)
            }
            return (feedback, nil, fallbackAttribution)
        case .clear:
            return (.clear, nil, nil)
        }
    }

    private func correctLocal(_ feedback: SpeakerFeedback) {
        guard !saving else { return }
        nameFocused = false
        let scope: SpeakerFeedbackScope = wholeGroup ? .cluster : .selection
        if let enqueueFeedback {
            do {
                let (validatedFeedback, optimisticSpeaker, optimisticAttribution) = try validateAndProject(feedback)
                enqueueFeedback(sources, speaker, validatedFeedback, scope, optimisticSpeaker, optimisticAttribution)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            return
        }
        saving = true
        let notifyChanged = changed
        Task {
            do {
                let freshSources = (try? await archive.resolveCurrentSpeakerSources(sources)) ?? sources
                try await archive.correctSpeakers(freshSources, feedback: feedback, scope: scope, deferGlobalRematch: true)
                saving = false
                dismiss()
                await notifyChanged()
            } catch {
                saving = false
                failure = error.localizedDescription
            }
        }
    }
}
