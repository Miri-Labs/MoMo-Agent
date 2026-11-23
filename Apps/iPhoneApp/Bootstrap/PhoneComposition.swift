import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoLink
import MoMoRecording

@MainActor
enum PhoneComposition {
    static func make() throws -> PhoneRuntime {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        var container = documents.deletingLastPathComponent()
        var connectsToWatch = true
#if DEBUG
        let testConfiguration = try PhoneUITestConfiguration.load(container: container)
        if let testConfiguration {
            container = testConfiguration.rootURL
            connectsToWatch = false
        }
#endif
        let support = container.appendingPathComponent("Library/Application Support/MoMoAgent", isDirectory: true)
        let directoryProtection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: directoryProtection)
        try? FileManager.default.setAttributes(directoryProtection, ofItemAtPath: support.path)

        // Clean up any legacy on-device iPhone speech model caches left by older builds.
        let legacySpeechCache = container.appendingPathComponent("Library/Caches/MoMoAgent/SpeechModels", isDirectory: true)
        let legacyDownloadedModels = support.appendingPathComponent("SpeechModels", isDirectory: true)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacySpeechCache)
            try? FileManager.default.removeItem(at: legacyDownloadedModels)
        }

        let identityURL = support.appendingPathComponent("device-id")
        let deviceID: UUID
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let saved = try String(contentsOf: identityURL, encoding: .utf8)
            guard let id = UUID(uuidString: saved) else { throw PhoneCompositionError.invalidIdentity }
            try? FileManager.default.setAttributes(directoryProtection, ofItemAtPath: identityURL.path)
            deviceID = id
        } else {
            deviceID = UUID()
            try Data(deviceID.uuidString.utf8).write(
                to: identityURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
        let archive = try ArchiveStore(rootURL: container, receiverDeviceID: deviceID)
        let playback = AudioPlaybackController(archive: archive)
        let remoteAgent = try PhoneRemoteAgent(directory: support.appendingPathComponent("MacAgent", isDirectory: true), archive: archive, deviceID: deviceID)
        let controls = try ControlInbox(directory: support.appendingPathComponent("ControlInbox", isDirectory: true))
        let identity = ReceiverIdentity(messageID: archive.libraryInstanceID, receiverDeviceID: deviceID,
                                        libraryInstanceID: archive.libraryInstanceID)
        let receiver = PhoneReceiveCoordinator(archive: archive, controls: controls, identity: identity)
        receiver.beginBackgroundSyncGrant = { [weak receiver] in
            PhoneConnectivityTask.beginHoldWindow {
                Task { @MainActor in
                    receiver?.releaseBackgroundSyncWindow()
                }
            }
        }
        let inbox = archive.inbox
        let phoneBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let transport: WatchConnectivityTransport?
        if connectsToWatch {
            let localSync = try? LocalSyncServer(
                handlers: LocalSyncHandlers(
                    receiverDeviceID: deviceID,
                    libraryInstanceID: archive.libraryInstanceID,
                    receiveChunk: { [weak receiver] envelope, data in
                        let grant = PhoneConnectivityTask.beginSync()
                        defer { grant.finish() }
                        let receipt = try await archive.receiveDirectChunk(
                            envelope: envelope,
                            audioData: data,
                            receiverDeviceID: deviceID,
                            libraryInstanceID: archive.libraryInstanceID)
                        Task { @MainActor in
                            receiver?.noteDirectChunkCommitted(chunkID: receipt.chunkID)
                        }
                        return receipt
                    },
                    applyReceipts: { [weak receiver] items in
                        let grant = PhoneConnectivityTask.beginSync()
                        defer { grant.finish() }
                        let applied = try await archive.applyReceipts(items)
                        if applied > 0 {
                            Task { @MainActor in
                                await receiver?.noteReceiptsAppliedFromLocalSync(items)
                            }
                        }
                        return applied
                    },
                    reconcile: { [weak receiver] request in
                        let grant = PhoneConnectivityTask.beginSync()
                        defer { grant.finish() }
                        Task { @MainActor in
                            receiver?.holdBackgroundSyncWindow(seconds: 15)
                        }
                        let response = try await archive.receiveReconcileRequest(request)
                        try await archive.markReconcileResponseSubmitted(messageID: response.messageID)
                        return response
                    }
                )
            )
            receiver.attachLocalSync(localSync)
            try? localSync?.start(onEndpointChanged: { [weak receiver] in
                Task { @MainActor in
                    await receiver?.publishStatus(refreshObservation: true)
                }
            })
            let live = try WatchConnectivityTransport(
                preserveFile: { url, envelope in _ = try inbox.preserve(fileURL: url, envelope: envelope) },
                preserveControl: { try controls.preserve($0) },
                event: { [weak receiver] event in
                    let grant = PhoneConnectivityTask.beginSync()
                    let task = Task { @MainActor in
                        defer { grant.finish() }
                        await receiver?.receive(event)
                    }
                    grant.attach(task)
                },
                diagnosticsURL: support.appendingPathComponent("file-queue-diagnostic.json"),
                receiveAudioBlock: { [weak receiver] block in
                    Task { @MainActor in
                        receiver?.holdBackgroundSyncWindow(seconds: 15)
                    }
                    return try await PhoneConnectivityTask.receiveAudioBlock(block, archive: archive)
                },
                statusReplyProvider: { [weak localSync, weak receiver] _ in
                    let grant = PhoneConnectivityTask.beginSync()
                    defer { grant.finish() }
                    Task { @MainActor in
                        receiver?.holdBackgroundSyncWindow(seconds: 15)
                    }
                    return try await archive.phoneStatus(
                        sourceBuild: phoneBuild,
                        localSync: localSync?.currentEndpoint(),
                        refreshObservation: true)
                },
                controlReplyProvider: { [weak receiver] message in
                    let grant = PhoneConnectivityTask.beginSync()
                    defer { grant.finish() }
                    return await receiver?.inlineControlReply(for: message)
                },
                controlScopeID: archive.libraryInstanceID
            )
            receiver.attach(live)
            transport = live
        } else { transport = nil }
#if DEBUG
        try testConfiguration?.stage(in: archive, controls: controls)
#endif
        // The phone is both source and receiver of earphone audio; its ledger lives beside the archive.
        let earphoneDirectory = support.appendingPathComponent("EarphoneCapture", isDirectory: true)
        let earphone = EarphoneCaptureRuntime(
            store: try RecordingStore(rootURL: earphoneDirectory.appendingPathComponent("Ledger", isDirectory: true)),
            archive: archive, deviceID: deviceID, sourceBuild: phoneBuild, directory: earphoneDirectory,
            settings: CaptureDeviceSettings())
        let runtime = try PhoneRuntime(
            archive: archive,
            remoteAgent: remoteAgent,
            playback: playback,
            receiver: receiver,
            transport: transport,
            deviceID: deviceID,
            earphone: earphone
        )
#if DEBUG
        runtime.uiTestConfiguration = testConfiguration
#endif
        return runtime
    }
}

enum PhoneCompositionError: Error { case invalidIdentity }
