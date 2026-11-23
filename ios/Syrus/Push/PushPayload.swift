import Foundation

/// Routing data carried in the `syrus` key of a push payload (see
/// `PushNotifications::Deliverer#payload_for` on the server).
struct PushPayload: Equatable {
    let notificationID: Int?
    let kind: String?
    let path: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let syrus = userInfo["syrus"] as? [String: Any] else { return nil }
        notificationID = syrus["notification_id"] as? Int
        kind = syrus["kind"] as? String
        // Only same-app paths are accepted; a push must never steer the web
        // view to another origin.
        if let path = syrus["path"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") {
            self.path = path
        } else {
            self.path = nil
        }
    }
}
