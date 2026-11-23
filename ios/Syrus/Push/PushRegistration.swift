import Foundation

/// Everything the server needs to know about this install.
struct PushRegistration: Equatable {
    let token: String
    let environment: String
    let bundleID: String
    let deviceName: String
    let appVersion: String

    static func hexToken(from deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    var jsonBody: [String: String] {
        [
            "token": token,
            "platform": "ios",
            "environment": environment,
            "bundle_id": bundleID,
            "device_name": deviceName,
            "app_version": appVersion,
        ]
    }
}

/// The in-page scripts used to talk to the Syrus API.
///
/// The app authenticates the same way the browser does — with the session
/// cookie the web view already holds — so registration runs as a `fetch` inside
/// the page. That keeps credentials out of native code and lets Rails associate
/// the device with the signed-in user and session. Arguments are passed as
/// `callAsyncJavaScript` arguments, never string-interpolated.
enum PushRegistrationScripts {
    static let register = """
    const meta = document.querySelector('meta[name="csrf-token"]');
    const response = await fetch(endpoint, {
      method: 'POST',
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

    static let unregister = """
    const meta = document.querySelector('meta[name="csrf-token"]');
    const response = await fetch(endpoint, {
      method: 'DELETE',
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

    static func registerArguments(server: ServerURL, registration: PushRegistration) -> [String: Any] {
        ["endpoint": endpoint(server, "/api/v1/app/push_devices"), "body": registration.jsonBody]
    }

    static func unregisterArguments(server: ServerURL, token: String) -> [String: Any] {
        ["endpoint": endpoint(server, "/api/v1/app/push_devices/destroy_by_token"), "body": ["token": token]]
    }

    private static func endpoint(_ server: ServerURL, _ path: String) -> String {
        server.resolving(path: path)?.absoluteString ?? ""
    }
}

/// Outcome of a registration attempt, derived from the HTTP status.
enum PushRegistrationOutcome: Equatable {
    case registered
    /// 401/403: the web view isn't signed in yet. Retried after the next page load.
    case signedOut
    case failed(Int)

    init(status: Int) {
        switch status {
        case 200...299: self = .registered
        case 401, 403: self = .signedOut
        default: self = .failed(status)
        }
    }
}
