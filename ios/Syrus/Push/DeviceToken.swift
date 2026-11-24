import Foundation

enum DeviceToken {
    /// APNs device tokens are opaque bytes; Syrus stores them hex-encoded.
    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
