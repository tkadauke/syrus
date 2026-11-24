import Foundation
import UIKit
import UserNotifications

/// UI-facing side of push: authorization prompts, APNs registration and
/// foreground presentation. Registration with the Syrus server is delegated to
/// `PushRegistrationService`.
@MainActor
final class PushCoordinator: ObservableObject {
    static let tokenDefaultsKey = "syrus.push.deviceToken"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    let service: PushRegistrationService
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.defaults = defaults
        self.center = center
        let bundle = Bundle.main
        let info = PushRegistrationService.DeviceInfo(
            bundleID: bundle.bundleIdentifier ?? "app.syrus.ios",
            apnsEnvironment: bundle.object(forInfoDictionaryKey: "SyrusAPNSEnvironment") as? String ?? "production",
            deviceName: UIDevice.current.name,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            osVersion: UIDevice.current.systemVersion
        )
        service = PushRegistrationService(info: info, token: defaults.string(forKey: Self.tokenDefaultsKey))
    }

    var statusLabel: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return String(localized: "Notifications on")
        case .denied: return String(localized: "Notifications off — open Settings")
        default: return String(localized: "Enable notifications")
        }
    }

    /// Call on launch / foreground. Already-authorized installs re-register with
    /// APNs (tokens can rotate) without prompting.
    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// User-initiated: prompt if undecided, deep-link to Settings if denied.
    func enableNotifications() async {
        await refreshAuthorization()
        switch authorization {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            authorization = granted ? .authorized : .denied
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
        default:
            break
        }
    }

    func didRegister(deviceToken data: Data) {
        let token = DeviceToken.hexString(from: data)
        defaults.set(token, forKey: Self.tokenDefaultsKey)
        service.update(token: token)
    }

    func didFailToRegister(_ error: Error) {
        NSLog("APNs registration failed: %@", error.localizedDescription)
    }
}
