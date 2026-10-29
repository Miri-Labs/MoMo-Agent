import Observation
import UIKit
import UserNotifications
import MoMoAgentClient
import MoMoArchive
import MoMoContracts

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let bootstrap = PhoneBootstrap()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        bootstrap.background.register()
        // WatchConnectivity can launch the process without creating a SwiftUI scene.
        bootstrap.launch()
        bootstrap.runtime?.remoteAgent.notifications.start()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        bootstrap.initialize(); bootstrap.runtime?.remoteAgent.notifications.registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        bootstrap.runtime?.remoteAgent.notifications.registrationFailed()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let value = notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
              let target = AgentNotificationTarget.parse(value) else { return [] }
        return await MainActor.run {
            guard let connection = bootstrap.runtime?.remoteAgent.connection, target.matches(connection) else { return [] }
            return bootstrap.runtime?.remoteAgent.notifications.shouldSuppress(target) == true ? [] : [.banner, .sound, .list]
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
              let target = AgentNotificationTarget.parse(value) else { return }
        await MainActor.run {
            bootstrap.initialize(); bootstrap.runtime?.remoteAgent.notifications.open(target)
        }
    }
}

@MainActor @Observable
final class PhoneBootstrap {
    private(set) var runtime: PhoneRuntime?
    private(set) var failure: String?
    @ObservationIgnored private let makeRuntime: @MainActor (PhoneBackgroundTasks) throws -> PhoneRuntime
    @ObservationIgnored lazy var background = PhoneBackgroundTasks { [weak self] in
        guard let self else { throw BackgroundTranscriptionError.runtimeUnavailable }
        initialize()
        guard let runtime else { throw BackgroundTranscriptionError.runtimeUnavailable }
        await runtime.start(backgroundOnly: true)
        return try runtime.backgroundCoordinator()
    }
    init(makeRuntime: @escaping @MainActor (PhoneBackgroundTasks) throws -> PhoneRuntime = {
        try PhoneComposition.make(background: $0)
    }) {
        self.makeRuntime = makeRuntime
    }

    func launch() {
        initialize()
        guard let runtime else { return }
        PhoneConnectivityTask.run { await runtime.start(backgroundOnly: true) }
    }

    func initialize() {
        guard runtime == nil else { return }
        do {
            runtime = try makeRuntime(background)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

/// Finish durable inbox processing before suspension; the OS still controls transfer scheduling.
@MainActor
final class PhoneConnectivityTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    private init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Receive Watch recordings") { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard identifier != .invalid else { return }
        let completed = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(completed)
    }

    static func run(_ operation: @escaping @MainActor () async -> Void) {
        let grant = PhoneConnectivityTask()
        Task { @MainActor in
            defer { grant.finish() }
            await operation()
        }
    }

    static func receiveAudioBlock(_ block: AudioBlock, archive: ArchiveStore) async throws -> AudioBlockReply {
        let grant = PhoneConnectivityTask()
        defer { grant.finish() }
        return try await archive.receiveAudioBlock(block)
    }
}
