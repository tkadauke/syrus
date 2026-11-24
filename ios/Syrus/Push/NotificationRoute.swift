import Foundation

/// Extracts the in-app destination from a Syrus push payload.
///
/// The server sends `{ "syrus": { "target_path": "/jobs/12", … } }`. Only
/// plain absolute paths are accepted; anything that could resolve to another
/// origin is rejected (see `ServerURL.resolving(path:)`).
enum NotificationRoute {
    static func targetPath(from userInfo: [AnyHashable: Any]) -> String? {
        guard let syrus = userInfo["syrus"] as? [String: Any],
              let path = syrus["target_path"] as? String,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\")
        else { return nil }
        return path
    }
}
