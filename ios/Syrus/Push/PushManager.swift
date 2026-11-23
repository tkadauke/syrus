import Foundation
import UIKit
import UserNotifications
import WebKit

/// Push foundation: permission, APNs token capture, and keeping the Syrus
/// server's device registry in step with the signed-in web session.
///
/// Flow: authorization is requested once a Syrus page has loaded; iOS hands the
/// device token to `AppDelegate`, which forwards it here; registration is then
/// attempted from inside the web view. A 401 means nobody is signed in yet, so
/// registration is retried after the next page load. Sign-out needs no client
/// work: the server drops devices bound to the destroyed session.
@MainActor
final class PushManager: NSObject, ObservableObject {
    enum Authorization: Equatable { case unknown, notDetermined, denied, authorized }

    static let tokenKey = "syrus.push.deviceToken.v1"
    static let registeredKey = "syrus.push.registered.v1"
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var authorization: Authorization = .unknown
    @Published var pendingTargetPath: String?

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private var registerInFlight = false

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.defaults = defaults
        self.center = center
        super.init()
        center.delegate = self
    }

    var deviceToken: String? { defaults.string(forKey: Self.tokenKey) }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = Self.map(settings.authorizationStatus)
        if authorization == .authorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Asks for permission (first time only) and registers with APNs.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        authorization = granted ? .authorized : .denied
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didRegister(deviceToken data: Data) {
        defaults.set(PushRegistration.hexString(from: data), forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.registeredKey)
    }

    func didFailToRegister(_ error: Error) {
        NSLog("Syrus: APNs registration failed: %@", error.localizedDescription)
    }

    /// Called after every Syrus page load; cheap when nothing needs doing.
    func syncRegistration(using webView: WKWebView, server: URL, now: Date = Date()) async {
        guard let token = deviceToken, !registerInFlight else { return }
        let marker = "\(server.absoluteString)|\(token)"
        if let last = defaults.dictionary(forKey: Self.registeredKey),
           last["marker"] as? String == marker,
           let at = last["at"] as? Date, now.timeIntervalSince(at) < Self.refreshInterval {
            return
        }
        registerInFlight = true
        defer { registerInFlight = false }
        let status = await send(method: "POST", body: PushRegistration.current(token: token).registerBody, in: webView)
        if status == 200 { defaults.set(["marker": marker, "at": now], forKey: Self.registeredKey) }
    }

    /// Removes this device from the server we are leaving. Best effort.
    func unregister(using webView: WKWebView) async {
        guard let token = deviceToken else { return }
        _ = await send(method: "DELETE", body: PushRegistration.current(token: token).unregisterBody, in: webView)
        defaults.removeObject(forKey: Self.registeredKey)
    }

    private func send(method: String, body: [String: String], in webView: WKWebView) async -> Int? {
        let result = try? await webView.callAsyncJavaScript(
            PushRegistration.fetchScript,
            arguments: ["path": PushRegistration.path, "method": method, "body": body],
            in: nil, contentWorld: .page
        )
        return result as? Int
    }

    nonisolated static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    /// Extracts the server-relative path a Syrus push wants opened.
    nonisolated static func targetPath(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["target_path"] as? String
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = Self.targetPath(from: response.notification.request.content.userInfo)
        await MainActor.run { self.pendingTargetPath = path ?? "/notifications" }
    }
}
