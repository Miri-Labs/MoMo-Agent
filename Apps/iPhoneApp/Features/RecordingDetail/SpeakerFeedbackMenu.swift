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
            .presentationDetents([.height(440), .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// Compact AI-native speaker quick-picker: type-or-tap people first, minimal scope & learn bar at bottom.
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
    @State private var query = ""
    @State private var loaded: Bool
    @State private var saving = false
    @State private var failure: String?

    private var macClient: AgentClient? { remoteAgent?.speechDataClient }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var ownerDisplayName: String {
        if let macOwner = macProfiles.first(where: \.isOwner) {
            return macOwner.name
        }
        return people.first(where: \.isUser)?.name ?? String(localized: "我")
    }

    private var matchesOwnerQuery: Bool {
        guard !trimmedQuery.isEmpty else { return true }
        if "我".localizedStandardContains(trimmedQuery) || ownerDisplayName.localizedStandardContains(trimmedQuery) {
            return true
        }
        if let macOwner = macProfiles.first(where: \.isOwner),
           macOwner.aliases.contains(where: { $0.localizedStandardContains(trimmedQuery) }) {
            return true
        }
        return false
    }

    private var filteredMacOthers: [VoiceprintProfile] {
        macProfiles.filter {
            !$0.isOwner && (trimmedQuery.isEmpty
                || $0.name.localizedStandardContains(trimmedQuery)
                || $0.aliases.contains(where: { $0.localizedStandardContains(trimmedQuery) }))
        }
    }

    private var filteredLocalOthers: [SpeakerProfile] {
        people.filter {
            !$0.isUser && (trimmedQuery.isEmpty || $0.name.localizedStandardContains(trimmedQuery))
        }
    }

    private var canCreateNewName: Bool {
        guard !trimmedQuery.isEmpty,
              trimmedQuery != "我",
              trimmedQuery.caseInsensitiveCompare(ownerDisplayName) != .orderedSame else { return false }
        if macClient != nil {
            return !macProfiles.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame })
        }
        return !people.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame })
    }

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
            List {
                // 1. Inline search / instant create field
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("选择或输入姓名", text: $query)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .onSubmit {
                                if canCreateNewName {
                                    chooseNewPerson(trimmedQuery)
                                } else if let match = filteredMacOthers.first {
                                    chooseMacPerson(match)
                                }
                            }
                            .accessibilityIdentifier("speaker.new.name")
                    }

                    if matchesOwnerQuery {
                        Button { chooseOwner() } label: {
                            profileRow(
                                name: ownerDisplayName,
                                isOwner: true,
                                selected: attribution?.isUser == true || speaker == ownerDisplayName || speaker == "我"
                            )
                        }
                        .accessibilityIdentifier("speaker.choose.owner")
                    }

                    if macClient != nil {
                        ForEach(filteredMacOthers) { person in
                            Button { chooseMacPerson(person) } label: {
                                profileRow(name: person.name, isOwner: false, selected: speaker == person.name)
                            }
                            .accessibilityIdentifier("speaker.choose.mac.\(person.id)")
                        }
                    } else {
                        ForEach(filteredLocalOthers) { person in
                            Button { correctLocal(.knownPerson(person.id)) } label: {
                                profileRow(name: person.name, isOwner: false, selected: attribution?.personID == person.id)
                            }
                            .accessibilityIdentifier("speaker.choose.\(person.id)")
                        }
                    }

                    if canCreateNewName {
                        Button {
                            chooseNewPerson(trimmedQuery)
                        } label: {
                            Label("新建「\(trimmedQuery)」", systemImage: "plus.circle.fill")
                                .foregroundStyle(MoMoPalette.ink)
                        }
                        .accessibilityIdentifier("speaker.new.save")
                    }
                }

                // 2. Compact options (zero essay footers)
                Section {
                    if groupCount > sources.count || macClient != nil {
                        HStack {
                            Text("范围")
                            Spacer()
                            Picker("", selection: $wholeGroup) {
                                Text("本场").tag(true)
                                Text("仅此句").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 140)
                        }
                    }
                    if macClient != nil {
                        Toggle("记住声纹", isOn: $enrollVoiceprint)
                            .accessibilityIdentifier("speaker.enroll.toggle")
                    }
                }

                if (macClient != nil && speaker != String(localized: "说话人") && !speaker.hasPrefix("说话人 "))
                    || (macClient == nil && attribution != nil) {
                    Section {
                        if macClient != nil, speaker != String(localized: "说话人"), !speaker.hasPrefix("说话人 ") {
                            Button("不是「\(speaker)」", role: .destructive) { rejectMacMatch() }
                        } else if let personID = attribution?.personID {
                            Button("不是「\(speaker)」", role: .destructive) { correctLocal(.notPerson(personID)) }
                        }
                        if attribution != nil, macClient == nil {
                            Button("撤销标记") { correctLocal(.clear) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .buttonStyle(.automatic)
            .disabled(!loaded || saving)
            .tint(MoMoPalette.ink)
            .phoneSoftTopEdge()
            .navigationTitle("这是谁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
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
            .alert("未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil; if !loaded { dismiss() } }
            } message: { Text(failure ?? "") }
        }
    }

    private func profileRow(name: String, isOwner: Bool, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOwner ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.07))
                .frame(width: 26, height: 26)
                .overlay {
                    Text(String(name.prefix(1)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOwner ? MoMoPalette.success : MoMoPalette.ink)
                }
            Text(name).foregroundStyle(MoMoPalette.ink)
            if isOwner {
                Text("本人")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(MoMoPalette.successBackground, in: Capsule())
                    .foregroundStyle(MoMoPalette.success)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOwner ? MoMoPalette.success : MoMoPalette.ink)
            }
        }
        .contentShape(Rectangle())
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
                    rematchHistory: enroll,
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
            return (.owner, ownerDisplayName, SpeakerAttribution(clusterID: clusterID, personID: ownerID, isUser: true, confirmed: true, canLearn: canLearn))
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
