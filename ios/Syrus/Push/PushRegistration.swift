import Foundation
import UIKit

/// Pure description of the registration calls made against the Syrus API.
/// Requests are executed *inside* the signed-in web view (same-origin, cookie
/// session + CSRF), so the app never handles credentials itself.
struct PushRegistration: Equatable {
    static let path = "/api/v1/app/push_devices"

    let token: String
    let environment: String
    let bundleID: String
    let deviceName: String
    let appVersion: String

    static func hexString(from deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// DEBUG builds are signed with the development APNs entitlement.
    static var currentEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func current(token: String) -> PushRegistration {
        PushRegistration(
            token: token,
            environment: currentEnvironment,
            bundleID: Bundle.main.bundleIdentifier ?? "estate.syrus.app",
            deviceName: UIDevice.current.name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
    }

    var registerBody: [String: String] {
        ["token": token, "platform": "ios", "environment": environment,
         "bundle_id": bundleID, "device_name": deviceName, "app_version": appVersion]
    }

    var unregisterBody: [String: String] { ["token": token, "platform": "ios"] }

    /// JavaScript run via `callAsyncJavaScript`; takes `method` and `body` arguments
    /// and resolves to the HTTP status code.
    static let fetchScript = """
    const meta = document.querySelector('meta[name="csrf-token"]');
    const response = await fetch(path, {
      method: method,
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': meta ? meta.content : ''
      },
      body: JSON.stringify(body)
    });
    return response.status;
    """
}
