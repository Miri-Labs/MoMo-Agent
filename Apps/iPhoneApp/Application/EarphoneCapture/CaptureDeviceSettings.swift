import Foundation
import Observation

enum CaptureDevice: String, CaseIterable, Identifiable, Sendable {
    case watch, earphone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .watch: String(localized: "Apple Watch")
        case .earphone: String(localized: "蓝牙耳机")
        }
    }
    var symbol: String {
        switch self {
        case .watch: "applewatch"
        case .earphone: "headphones"
        }
    }
}

/// One recording device at a time. Apple Watch stays the default, so existing users see no change.
@MainActor @Observable
final class CaptureDeviceSettings {
    static let deviceKey = "capture.device"
    static let earphoneStoppedKey = "capture.earphoneStoppedByUser"
    private(set) var device: CaptureDevice
    /// A manual stop is respected across launches until the user starts again.
    private(set) var earphoneStoppedByUser: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        device = defaults.string(forKey: Self.deviceKey).flatMap(CaptureDevice.init(rawValue:)) ?? .watch
        earphoneStoppedByUser = defaults.bool(forKey: Self.earphoneStoppedKey)
    }

    func select(_ device: CaptureDevice) {
        guard self.device != device else { return }
        self.device = device
        defaults.set(device.rawValue, forKey: Self.deviceKey)
        // Choosing the earphone is an explicit request to record with it.
        if device == .earphone { setEarphoneStoppedByUser(false) }
    }

    func setEarphoneStoppedByUser(_ stopped: Bool) {
        earphoneStoppedByUser = stopped
        defaults.set(stopped, forKey: Self.earphoneStoppedKey)
    }
}
