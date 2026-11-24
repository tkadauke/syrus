import Foundation

enum DeviceToken {
    /// APNs device tokens are opaque bytes; Syrus stores them hex-encoded.
    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Diagnostics never show a full token (it is a push credential): only the
    /// length and the last six characters, enough to match the server's list.
    static func redacted(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "—" }
        return "…\(token.suffix(6)) (\(token.count) chars)"
    }
}
