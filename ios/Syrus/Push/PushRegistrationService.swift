import Foundation

/// Keeps the Syrus server's `mobile_devices` registry in step with the APNs
/// token this installation holds. Contains no UIKit so it is unit-testable.
///
/// Endpoints (see `docs` in `ios/README.md`):
/// * `POST   /api/v1/app/mobile_devices`            register / refresh
/// * `DELETE /api/v1/app/mobile_devices/unregister` remove
@MainActor
final class PushRegistrationService {
    static let registerPath = "/api/v1/app/mobile_devices"
    static let unregisterPath = "/api/v1/app/mobile_devices/unregister"

    struct DeviceInfo {
        var bundleID: String
        var apnsEnvironment: String
        var deviceName: String
        var appVersion: String
        var osVersion: String
    }

    /// What the last attempt to register this token with the server did.
    /// Surfaced by diagnostics so a tester can see *why* sync hasn't happened.
    enum SyncOutcome: Equatable {
        case notAttempted
        case noToken
        /// The web view isn't on the server's origin yet, so no request was made.
        case pageNotReady
        /// 401/403: the web view has no signed-in session.
        case signedOut(Int)
        case failed(Int)
        case synced
    }

    private(set) var token: String?
    private(set) var lastSync: SyncOutcome = .notAttempted
    private var lastSyncedKey: String?
    let info: DeviceInfo

    init(info: DeviceInfo, token: String? = nil) {
        self.info = info
        self.token = token
    }

    /// Records a new token; invalidates the "already synced" marker if it changed.
    func update(token newToken: String) {
        if newToken != token { lastSyncedKey = nil }
        token = newToken
    }

    /// Registers the token with `server` through the signed-in web view.
    /// Safe to call repeatedly: it is a no-op once synced for this
    /// (server, token) pair and retries silently while the user isn't signed in.
    @discardableResult
    func syncIfNeeded(server: ServerURL, via performer: WebRequestPerforming) async -> Bool {
        guard let token else { lastSync = .noToken; return false }
        let key = "\(server.description)|\(token)"
        if lastSyncedKey == key { return true }

        let body: [String: Any] = [
            "platform": "ios",
            "token": token,
            "bundle_id": info.bundleID,
            "apns_environment": info.apnsEnvironment,
            "device_name": info.deviceName,
            "app_version": info.appVersion,
            "os_version": info.osVersion,
        ]
        guard let status = try? await performer.send(method: "POST", path: Self.registerPath, jsonBody: body) else {
            lastSync = .pageNotReady
            return false
        }
        guard (200..<300).contains(status) else {
            lastSync = (status == 401 || status == 403) ? .signedOut(status) : .failed(status)
            return false
        }
        lastSyncedKey = key
        lastSync = .synced
        return true
    }

    /// Removes this token from `server` (used when leaving a server).
    func unregister(via performer: WebRequestPerforming) async {
        guard let token else { return }
        _ = try? await performer.send(method: "DELETE", path: Self.unregisterPath, jsonBody: ["platform": "ios", "token": token])
        lastSyncedKey = nil
        lastSync = .notAttempted
    }

    func resetSyncState() {
        lastSyncedKey = nil
        lastSync = .notAttempted
    }
}
