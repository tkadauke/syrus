import UIKit

/// Forwards APNs callbacks, which SwiftUI does not expose, to `PushManager`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var pushManager: PushManager?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in pushManager?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in pushManager?.didFailToRegister(error) }
    }
}
