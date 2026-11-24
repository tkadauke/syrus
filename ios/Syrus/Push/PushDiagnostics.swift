import Foundation
import UserNotifications

/// Server-side view of this user's registered devices, from
/// `GET /api/v1/app/mobile_devices`. Tokens are never sent in full.
struct ServerPushState: Equatable {
    struct Device: Equatable {
        var id: Int
        var environment: String
        var tokenSuffix: String
        var disabledReason: String?
        var isActive: Bool
        var lastDeliveredAt: String?
    }

    var apnsConfigured: Bool
    var devices: [Device]

    /// The server row matching this installation's token, if any.
    func device(matching token: String?) -> Device? {
        guard let token, !token.isEmpty else { return nil }
        return devices.first { token.hasSuffix($0.tokenSuffix) }
    }

    init(apnsConfigured: Bool, devices: [Device]) {
        self.apnsConfigured = apnsConfigured
        self.devices = devices
    }

    init?(json: [String: Any]) {
        guard let rows = json["mobile_devices"] as? [[String: Any]] else { return nil }
        apnsConfigured = json["apns_configured"] as? Bool ?? false
        devices = rows.compactMap { row in
            guard let id = (row["id"] as? NSNumber)?.intValue, let suffix = row["token_suffix"] as? String else { return nil }
            let reason = row["disabled_reason"] as? String
            return Device(
                id: id,
                environment: row["apns_environment"] as? String ?? "?",
                tokenSuffix: suffix,
                disabledReason: reason,
                isActive: row["disabled_at"] is NSNull || row["disabled_at"] == nil,
                lastDeliveredAt: row["last_delivered_at"] as? String
            )
        }
    }
}

/// Result of probing the server through the signed-in web view.
enum ServerProbe: Equatable {
    case notChecked
    case pageNotReady
    case signedOut
    case failed(Int)
    case signedIn(ServerPushState)
}

/// Result of "Send test notification".
enum TestPushOutcome: Equatable {
    case sent(deepLink: String)
    case apnsNotConfigured
    case noRegisteredDevice
    case signedOut
    case pageNotReady
    /// APNs refused the token (wrong environment/topic, or stale token).
    case tokenRejected(String)
    case failed(String)
}

extension PushRegistrationService {
    static let testNotificationPath = "/api/v1/app/mobile_devices/test_notification"

    func probeServer(via performer: WebRequestPerforming) async -> ServerProbe {
        guard let response = try? await performer.perform(method: "GET", path: Self.registerPath, jsonBody: [:]) else {
            return .pageNotReady
        }
        switch response.status {
        case 200..<300:
            guard let json = response.json, let state = ServerPushState(json: json) else { return .failed(response.status) }
            return .signedIn(state)
        case 401, 403:
            return .signedOut
        default:
            return .failed(response.status)
        }
    }

    /// Asks the server to push a test notification to this user's device(s),
    /// narrowed to this installation's token when it has one.
    func sendTestNotification(via performer: WebRequestPerforming) async -> TestPushOutcome {
        let body: [String: Any] = token.map { ["token": $0] } ?? [:]
        guard let response = try? await performer.perform(method: "POST", path: Self.testNotificationPath, jsonBody: body) else {
            return .pageNotReady
        }
        let json = response.json
        switch response.status {
        case 200..<300:
            let results = json?["results"] as? [[String: Any]] ?? []
            if let rejected = results.first(where: { $0["outcome"] as? String == "token_rejected" }) {
                return .tokenRejected(rejected["reason"] as? String ?? "unknown")
            }
            if (json?["delivered"] as? NSNumber)?.intValue ?? 0 > 0 {
                return .sent(deepLink: json?["target_path"] as? String ?? "/")
            }
            let detail = results.compactMap { ($0["reason"] as? String) ?? ($0["outcome"] as? String) }.first
            return .failed(detail ?? "APNs did not accept the push")
        case 401, 403:
            return .signedOut
        default:
            switch (json?["error"] as? [String: Any])?["code"] as? String {
            case "apns_not_configured": return .apnsNotConfigured
            case "no_registered_device": return .noRegisteredDevice
            default: return .failed("HTTP \(response.status)")
            }
        }
    }
}

/// Last notification-related events seen by this installation. Kept in memory
/// only; payload contents beyond the route are not retained.
struct PushEventLog: Equatable {
    struct Event: Equatable {
        var date: Date
        var summary: String
    }

    var lastPush: Event?
    var lastDeepLink: Event?
    var registrationError: Event?

    mutating func pushReceived(userInfo: [AnyHashable: Any], foreground: Bool, at date: Date = Date()) {
        let kind = NotificationRoute.kind(from: userInfo) ?? "notification"
        lastPush = Event(date: date, summary: "\(kind) (\(foreground ? "foreground" : "tapped"))")
    }

    mutating func deepLink(_ outcome: NotificationRoute.Outcome, at date: Date = Date()) {
        switch outcome {
        case .path(let path): lastDeepLink = Event(date: date, summary: "opened \(path)")
        case .noTarget: lastDeepLink = Event(date: date, summary: "no target_path in payload")
        case .rejected(let raw): lastDeepLink = Event(date: date, summary: "rejected target “\(raw.prefix(60))”")
        }
    }

    mutating func registrationFailed(_ message: String, at date: Date = Date()) {
        registrationError = Event(date: date, summary: message)
    }

    mutating func registrationSucceeded() { registrationError = nil }
}

/// One row of the diagnostics screen.
struct DiagnosticsRow: Equatable, Identifiable {
    enum Status: Equatable { case ok, warning, problem, info }
    var id: String { title }
    var title: String
    var value: String
    var status: Status
}

/// Pure projection of the app's push state into display rows, so each failure
/// state is unit-testable without UIKit. Contains no secrets and never a full
/// device token.
struct DiagnosticsInput {
    var server: ServerURL?
    var authorization: UNAuthorizationStatus
    var token: String?
    var apnsEnvironment: String
    var bundleID: String
    var appVersion: String
    var buildNumber: String
    var sync: PushRegistrationService.SyncOutcome
    var probe: ServerProbe
    var events: PushEventLog
}

enum DiagnosticsReport {
    static func rows(for input: DiagnosticsInput) -> [DiagnosticsRow] {
        var rows: [DiagnosticsRow] = []
        rows.append(.init(title: "Server", value: input.server?.description ?? "None selected", status: input.server == nil ? .problem : .info))
        rows.append(session(input))
        rows.append(authorization(input.authorization))
        rows.append(.init(
            title: "APNs token",
            value: input.token == nil ? "Not received" : DeviceToken.redacted(input.token),
            status: input.token == nil ? .problem : .ok
        ))
        rows.append(.init(title: "APNs environment", value: "\(input.apnsEnvironment) · \(input.bundleID)", status: .info))
        rows.append(sync(input))
        rows.append(serverRegistration(input))
        rows.append(.init(title: "App version", value: "\(input.appVersion) (\(input.buildNumber))", status: .info))
        rows.append(event("Last push", input.events.lastPush))
        rows.append(event("Last deep link", input.events.lastDeepLink))
        if let error = input.events.registrationError {
            rows.append(.init(title: "APNs registration error", value: error.summary, status: .problem))
        }
        return rows
    }

    static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .denied: return "Denied — enable in iOS Settings"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    private static func authorization(_ status: UNAuthorizationStatus) -> DiagnosticsRow {
        let ok = status == .authorized || status == .provisional || status == .ephemeral
        return .init(title: "Notification permission", value: label(for: status), status: ok ? .ok : .problem)
    }

    private static func session(_ input: DiagnosticsInput) -> DiagnosticsRow {
        switch input.probe {
        case .signedIn: return .init(title: "Session", value: "Signed in", status: .ok)
        case .signedOut: return .init(title: "Session", value: "Signed out — sign in in the app", status: .problem)
        case .pageNotReady: return .init(title: "Session", value: "Web page not loaded yet", status: .warning)
        case .failed(let status): return .init(title: "Session", value: "Server error (HTTP \(status))", status: .problem)
        case .notChecked: return .init(title: "Session", value: "Not checked — tap Refresh", status: .warning)
        }
    }

    private static func sync(_ input: DiagnosticsInput) -> DiagnosticsRow {
        let title = "Token sync"
        switch input.sync {
        case .synced: return .init(title: title, value: "Registered with server", status: .ok)
        case .notAttempted: return .init(title: title, value: "Not attempted yet", status: .warning)
        case .noToken: return .init(title: title, value: "Waiting for an APNs token", status: .warning)
        case .pageNotReady: return .init(title: title, value: "Waiting for the web page", status: .warning)
        case .signedOut(let status): return .init(title: title, value: "Rejected: not signed in (HTTP \(status))", status: .problem)
        case .failed(let status): return .init(title: title, value: "Server rejected registration (HTTP \(status))", status: .problem)
        }
    }

    private static func serverRegistration(_ input: DiagnosticsInput) -> DiagnosticsRow {
        let title = "Server push status"
        guard case .signedIn(let state) = input.probe else {
            return .init(title: title, value: "Unknown until signed in", status: .warning)
        }
        if !state.apnsConfigured {
            return .init(title: title, value: "APNs is not configured on this server", status: .problem)
        }
        guard let device = state.device(matching: input.token) else {
            return .init(title: title, value: "This device is not registered", status: .problem)
        }
        if !device.isActive {
            return .init(title: title, value: "Disabled by server: \(device.disabledReason ?? "unknown")", status: .problem)
        }
        if device.environment != input.apnsEnvironment {
            return .init(title: title, value: "Environment mismatch: server has \(device.environment)", status: .problem)
        }
        return .init(title: title, value: "Registered (\(device.environment))", status: .ok)
    }

    private static func event(_ title: String, _ event: PushEventLog.Event?) -> DiagnosticsRow {
        guard let event else { return .init(title: title, value: "None yet", status: .info) }
        return .init(title: title, value: "\(event.summary) · \(event.date.formatted(date: .omitted, time: .standard))", status: .info)
    }
}
