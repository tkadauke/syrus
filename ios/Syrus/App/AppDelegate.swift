import UIKit

/// APNs callbacks have no SwiftUI equivalent, so they come through a delegate
/// and are forwarded to the `PushCoordinator`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let push = PushCoordinator()

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        push.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        push.didFailToRegister(error)
    }
}
