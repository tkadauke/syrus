import Foundation

/// A validated Syrus server origin (scheme + host + optional port).
///
/// Operators type things like `syrus.example.com` or `localhost:3000`; this
/// type normalises them to an origin so cookies, navigation policy and API
/// calls all agree on what "the server" is.
struct ServerURL: Equatable, Hashable, Codable, CustomStringConvertible {
    enum ParseError: Error, Equatable {
        case empty
        case invalid
        case unsupportedScheme(String)
    }

    let url: URL

    var description: String { url.absoluteString }
    var host: String { url.host ?? "" }

    /// Parses user input into an origin. Scheme defaults to `https`, except for
    /// local development hosts (`localhost`, loopback, `*.local`) which default
    /// to `http`. Any path, query or fragment is dropped.
    static func parse(_ input: String) throws -> ServerURL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let candidate = trimmed.contains("://") ? trimmed : "\(defaultScheme(for: trimmed))://\(trimmed)"
        guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else {
            throw ParseError.invalid
        }
        guard let scheme = components.scheme?.lowercased() else { throw ParseError.invalid }
        guard scheme == "http" || scheme == "https" else { throw ParseError.unsupportedScheme(scheme) }

        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let url = components.url else { throw ParseError.invalid }
        return ServerURL(url: url)
    }

    /// Resolves an in-app path (e.g. `/jobs/12`) against this server.
    /// Returns nil for anything that is not a plain absolute path, so a
    /// malicious payload cannot redirect the web view to another origin.
    func resolving(path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\") else { return nil }
        guard let resolved = URL(string: path, relativeTo: url)?.absoluteURL else { return nil }
        return sameOrigin(as: resolved) ? resolved : nil
    }

    func sameOrigin(as other: URL) -> Bool {
        other.scheme?.lowercased() == url.scheme
            && other.host?.lowercased() == url.host?.lowercased()
            && (other.port ?? Self.defaultPort(for: other.scheme)) == (url.port ?? Self.defaultPort(for: url.scheme))
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func defaultScheme(for input: String) -> String {
        let host = input.split(separator: "/").first.map(String.init) ?? input
        let bare = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        let isLocal = bare == "localhost" || bare == "127.0.0.1" || bare == "::1" || bare == "[::1]" || bare.hasSuffix(".local")
        return isLocal ? "http" : "https"
    }
}

extension ServerURL.ParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "Enter your Syrus server address.")
        case .invalid: return String(localized: "That doesn’t look like a valid server address.")
        case .unsupportedScheme(let scheme): return String(localized: "“\(scheme)” isn’t supported. Use http or https.")
        }
    }
}
