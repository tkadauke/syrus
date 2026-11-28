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
    @Published private(set) var events = PushEventLog()
    @Published private(set) var probe: ServerProbe = .notChecked
    @Published private(set) var testOutcome: TestPushOutcome?
    @Published private(set) var isBusy = false

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
        events.registrationSucceeded()
    }

    func didFailToRegister(_ error: Error) {
        NSLog("APNs registration failed: %@", error.localizedDescription)
        events.registrationFailed(error.localizedDescription)
    }

    // MARK: Diagnostics

    func notificationPresented(userInfo: [AnyHashable: Any]) {
        events.pushReceived(userInfo: userInfo, foreground: true)
    }

    /// Records a tap and returns the path to open, if the payload carries a valid one.
    func notificationTapped(userInfo: [AnyHashable: Any]) -> String? {
        events.pushReceived(userInfo: userInfo, foreground: false)
        let outcome = NotificationRoute.outcome(from: userInfo)
        events.deepLink(outcome)
        if case .path(let path) = outcome { return path }
        return nil
    }

    /// Forgets per-server diagnostics state when the operator leaves a server.
    func resetServerState() {
        probe = .notChecked
        testOutcome = nil
    }

    func refreshDiagnostics(server: ServerURL?, via performer: WebRequestPerforming) async {
        await refreshAuthorization()
        isBusy = true
        defer { isBusy = false }
        // Sync first so the authoritative probe reflects any registration this
        // refresh performs (new device, re-enabled or updated environment).
        if let server { _ = await service.syncIfNeeded(server: server, via: performer) }
        probe = await service.probeServer(via: performer)
    }

    func sendTestNotification(via performer: WebRequestPerforming) async {
        isBusy = true
        defer { isBusy = false }
        testOutcome = await service.sendTestNotification(via: performer)
    }

    func diagnosticsRows(server: ServerURL?) -> [DiagnosticsRow] {
        let bundle = Bundle.main
        return DiagnosticsReport.rows(for: DiagnosticsInput(
            server: server,
            authorization: authorization,
            token: service.token,
            apnsEnvironment: service.info.apnsEnvironment,
            bundleID: service.info.bundleID,
            appVersion: service.info.appVersion,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            sync: service.lastSync,
            probe: probe,
            events: events
        ))
    }
}
