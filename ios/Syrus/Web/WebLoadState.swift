import Foundation

/// What the web container is currently showing.
enum WebLoadState: Equatable {
    case idle
    case loading(progress: Double)
    case loaded
    case failed(WebLoadFailure)
}

struct WebLoadFailure: Equatable {
    let title: String
    let message: String

    /// Turns a `URLError`-style failure into operator-facing guidance. Pass the
    /// server so the message can name what could not be reached.
    static func make(from error: Error, server: ServerURL) -> WebLoadFailure {
        let code = (error as? URLError)?.code
        switch code {
        case .some(.notConnectedToInternet), .some(.networkConnectionLost):
            return WebLoadFailure(title: "You're offline", message: "Check your connection and try again.")
        case .some(.cannotFindHost), .some(.dnsLookupFailed):
            return WebLoadFailure(title: "Server not found", message: "Couldn't find \(server.host). Check the address.")
        case .some(.cannotConnectToHost), .some(.timedOut):
            return WebLoadFailure(title: "Server unreachable", message: "\(server.host) didn't respond. Is Syrus running and reachable from this device?")
        case .some(.serverCertificateUntrusted), .some(.secureConnectionFailed), .some(.serverCertificateHasBadDate), .some(.serverCertificateHasUnknownRoot):
            return WebLoadFailure(title: "Secure connection failed", message: "The certificate for \(server.host) isn't trusted by this device.")
        default:
            return WebLoadFailure(title: "Couldn't load Syrus", message: error.localizedDescription)
        }
    }

    static func http(status: Int, server: ServerURL) -> WebLoadFailure {
        WebLoadFailure(title: "Server error", message: "\(server.host) responded with HTTP \(status).")
    }
}
