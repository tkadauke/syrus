import Foundation

/// A user-presentable explanation of why the web view could not show the page.
///
/// The central job of this type is attribution: the operator testing the app
/// must be able to tell whether the problem is the *network* (offline, DNS,
/// timeouts), the *server* (5xx, dropped connections, certificates), the
/// *session* (expired sign-in), or the *app* itself (web content crashed).
struct WebFailure: Equatable {
    enum Source: String, Equatable {
        case network
        case server
        case session
        case app

        var label: String {
            switch self {
            case .network: return String(localized: "Network problem")
            case .server: return String(localized: "Server problem")
            case .session: return String(localized: "Session expired")
            case .app: return String(localized: "App problem")
            }
        }
    }

    enum Kind: Equatable {
        case offline
        case timedOut
        case unreachable
        case untrustedCertificate
        case secureConnectionFailed
        case connectionLost
        case serverError(Int)
        case authExpired(Int)
        case contentCrashed
        case other(String)
    }

    let kind: Kind

    var source: Source {
        switch kind {
        case .offline, .timedOut, .unreachable: return .network
        case .untrustedCertificate, .secureConnectionFailed, .connectionLost, .serverError, .other: return .server
        case .authExpired: return .session
        case .contentCrashed: return .app
        }
    }

    var title: String {
        switch kind {
        case .offline: return String(localized: "You’re offline")
        case .timedOut: return String(localized: "Server took too long to respond")
        case .unreachable: return String(localized: "Can’t reach the server")
        case .untrustedCertificate: return String(localized: "Certificate not trusted")
        case .secureConnectionFailed: return String(localized: "Secure connection failed")
        case .connectionLost: return String(localized: "Connection interrupted")
        case .serverError: return String(localized: "The server reported an error")
        case .authExpired: return String(localized: "Please sign in again")
        case .contentCrashed: return String(localized: "The page stopped unexpectedly")
        case .other: return String(localized: "Can’t load Syrus")
        }
    }

    var message: String {
        switch kind {
        case .offline:
            return String(localized: "This device has no internet connection. The page will reload when you’re back online.")
        case .timedOut:
            return String(localized: "The request timed out. Your network may be slow or the server may be overloaded.")
        case .unreachable:
            return String(localized: "Check the server address and that your network can reach it (VPN, Wi‑Fi, firewall).")
        case .untrustedCertificate:
            return String(localized: "The server’s certificate isn’t trusted by this device. The server certificate (or its CA) needs fixing; retrying won’t help.")
        case .secureConnectionFailed:
            return String(localized: "A secure connection to the server couldn’t be established. Check the server’s HTTPS configuration.")
        case .connectionLost:
            return String(localized: "The connection to the server dropped mid-request. Try again.")
        case .serverError(let status):
            return String(localized: "The server answered with HTTP \(status). This is a server-side problem; try again shortly.")
        case .authExpired(let status):
            return String(localized: "The server rejected your session (HTTP \(status)). Sign in again to continue.")
        case .contentCrashed:
            return String(localized: "The web content process was terminated by iOS, usually to reclaim memory. Reload to continue.")
        case .other(let detail):
            return detail
        }
    }

    var systemImage: String {
        switch kind {
        case .offline: return "wifi.slash"
        case .timedOut, .unreachable: return "wifi.exclamationmark"
        case .untrustedCertificate, .secureConnectionFailed: return "lock.trianglebadge.exclamationmark"
        case .connectionLost, .serverError, .other: return "server.rack"
        case .authExpired: return "person.crop.circle.badge.exclamationmark"
        case .contentCrashed: return "exclamationmark.triangle"
        }
    }

    /// Retrying cannot fix a bad certificate; the UI de-emphasizes it.
    var retryCanHelp: Bool {
        switch kind {
        case .untrustedCertificate: return false
        default: return true
        }
    }

    var retryTitle: String {
        if case .authExpired = kind { return String(localized: "Sign in again") }
        return String(localized: "Try again")
    }

    /// Whether going back online should automatically retry.
    var retriesWhenOnline: Bool {
        switch kind {
        case .offline, .timedOut, .unreachable, .connectionLost: return true
        default: return false
        }
    }

    /// One string for VoiceOver announcements and the combined element label.
    var spokenSummary: String { "\(source.label). \(title). \(message)" }

    // MARK: - Classification

    static func classify(_ error: NSError) -> WebFailure {
        guard error.domain == NSURLErrorDomain else {
            return WebFailure(kind: .other(error.localizedDescription))
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return WebFailure(kind: .offline)
        case NSURLErrorTimedOut:
            return WebFailure(kind: .timedOut)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
            return WebFailure(kind: .unreachable)
        case NSURLErrorNetworkConnectionLost:
            return WebFailure(kind: .connectionLost)
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected:
            return WebFailure(kind: .untrustedCertificate)
        case NSURLErrorSecureConnectionFailed:
            return WebFailure(kind: .secureConnectionFailed)
        default:
            return WebFailure(kind: .other(error.localizedDescription))
        }
    }

    /// Classifies a main-frame HTTP status. Returns nil when the page should
    /// simply be shown (2xx/3xx, and 4xx pages the server rendered itself).
    static func classify(statusCode: Int) -> WebFailure? {
        switch statusCode {
        case 401, 403: return WebFailure(kind: .authExpired(statusCode))
        case 500...599: return WebFailure(kind: .serverError(statusCode))
        default: return nil
        }
    }

    /// Superseded navigations are not failures.
    static func isCancellation(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
