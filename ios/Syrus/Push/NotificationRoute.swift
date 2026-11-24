import Foundation

/// Extracts the in-app destination from a Syrus push payload.
///
/// The server sends `{ "syrus": { "target_path": "/jobs/12", … } }`. Only
/// plain absolute paths are accepted; anything that could resolve to another
/// origin is rejected (see `ServerURL.resolving(path:)`).
enum NotificationRoute {
    enum Outcome: Equatable {
        case path(String)
        /// The payload has no `syrus.target_path`.
        case noTarget
        /// A target was present but is not a plain same-origin path.
        case rejected(String)
    }

    static func outcome(from userInfo: [AnyHashable: Any]) -> Outcome {
        guard let syrus = userInfo["syrus"] as? [String: Any], let raw = syrus["target_path"] else { return .noTarget }
        guard let path = raw as? String, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\") else {
            return .rejected(String(describing: raw))
        }
        return .path(path)
    }

    static func targetPath(from userInfo: [AnyHashable: Any]) -> String? {
        if case .path(let path) = outcome(from: userInfo) { return path }
        return nil
    }

    /// The `syrus.kind` of a payload (`"test"` for diagnostics pushes).
    static func kind(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["syrus"] as? [String: Any])?["kind"] as? String
    }
}
