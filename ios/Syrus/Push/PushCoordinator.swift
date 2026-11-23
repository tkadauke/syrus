import Foundation
import UIKit
import UserNotifications

/// Owns the push-notification lifecycle: asking permission, receiving the APNs
/// device token, registering it with the signed-in Syrus server, and routing
/// notification taps to the right page.
@MainActor
final class PushCoordinator: NSObject, ObservableObject {
    @Published private(set) var deviceToken: String?
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastOutcome: PushRegistrationOutcome?
    /// Set when a notification is tapped; consumed by the web container.
    @Published var pendingPath: String?

    private let center: UNUserNotificationCenter
    private let application: UIApplication
    private let minimumRegistrationInterval: TimeInterval = 5
    private var lastAttempt: Date?
    private var registeredServer: ServerURL?

    init(center: UNUserNotificationCenter = .current(), application: UIApplication? = nil) {
        self.center = center
        self.application = application ?? UIApplication.shared
        super.init()
        center.delegate = self
    }

    /// Called once the operator is looking at Syrus content, so the system
    /// permission prompt appears in context rather than at launch.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            authorizationStatus = granted ? .authorized : .denied
            if granted { application.registerForRemoteNotifications() }
        case .authorized, .provisional, .ephemeral:
            application.registerForRemoteNotifications()
        default:
            break
        }
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = PushRegistration.hexToken(from: data)
    }

    func didFailToRegister(_ error: Error) {
        deviceToken = nil
    }

    func registration() -> PushRegistration? {
        guard let token = deviceToken else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return PushRegistration(
            token: token,
            environment: info["SyrusAPNSEnvironment"] as? String ?? "production",
            bundleID: Bundle.main.bundleIdentifier ?? "",
            deviceName: UIDevice.current.name,
            appVersion: "\(version) (\(build))"
        )
    }

    /// Registers this device with the server loaded in `web`, if we have a
    /// token. Safe to call after every page load: the server upserts.
    func registerIfPossible(using web: WebScriptRunner, server: ServerURL, now: Date = Date()) async {
        guard let registration = registration() else { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumRegistrationInterval { return }
        lastAttempt = now

        let status = await web.runScript(
            PushRegistrationScripts.register,
            arguments: PushRegistrationScripts.registerArguments(server: server, registration: registration)
        )
        let outcome = status.map(PushRegistrationOutcome.init(status:)) ?? .failed(0)
        lastOutcome = outcome
        if outcome == .registered { registeredServer = server }
    }

    /// Removes this device from the server it last registered with, so a
    /// switched-away server stops pushing to the phone.
    func unregister(using web: WebScriptRunner, server: ServerURL) async {
        guard let token = deviceToken, registeredServer == server else { return }
        _ = await web.runScript(
            PushRegistrationScripts.unregister,
            arguments: PushRegistrationScripts.unregisterArguments(server: server, token: token)
        )
        registeredServer = nil
        lastAttempt = nil
    }

    func handleTap(userInfo: [AnyHashable: Any]) {
        guard let path = PushPayload(userInfo: userInfo)?.path else { return }
        pendingPath = path
    }
}

extension PushCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let path = PushPayload(userInfo: response.notification.request.content.userInfo)?.path
        await MainActor.run { pendingPath = path ?? pendingPath }
    }
}
