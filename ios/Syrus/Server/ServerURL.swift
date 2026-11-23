import Foundation

/// A validated Syrus server base URL.
///
/// Operators type things like `syrus.example.com`, `192.168.1.20:3000` or a full
/// URL. `ServerURL.parse` turns that into a normalized origin (scheme + host +
/// optional port, no trailing path) or explains why it can't.
struct ServerURL: Equatable, Hashable, Codable {
    enum ParseError: Error, Equatable {
        case empty
        case invalid
        case unsupportedScheme(String)
    }

    let url: URL

    var absoluteString: String { url.absoluteString }
    var host: String { url.host ?? "" }
    var isInsecure: Bool { url.scheme == "http" }

    /// `localhost`, loopback, RFC 1918 and `.local` hosts default to `http`
    /// when no scheme is typed; everything else defaults to `https`.
    static func parse(_ input: String) -> Result<ServerURL, ParseError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var candidate = trimmed
        if !candidate.contains("://") {
            let hostPart = candidate.split(separator: "/", maxSplits: 1).first.map(String.init) ?? candidate
            let scheme = isPrivateHost(hostWithoutPort(hostPart)) ? "http" : "https"
            candidate = "\(scheme)://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { return .failure(.invalid) }
        guard scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme(scheme))
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        // Keep a path prefix so Syrus can live behind a reverse-proxy subpath.
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path

        guard let url = components.url else { return .failure(.invalid) }
        return .success(ServerURL(url: url))
    }

    /// Resolves an in-app path such as `/jobs/42` against this server.
    func resolving(path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.path = components.path + String(split[0])
        components.query = split.count > 1 ? String(split[1]) : nil
        return components.url
    }

    /// True when `other` belongs to the same origin (scheme, host, port).
    func isSameOrigin(as other: URL) -> Bool {
        url.scheme?.lowercased() == other.scheme?.lowercased()
            && url.host?.lowercased() == other.host?.lowercased()
            && (url.port ?? Self.defaultPort(url.scheme)) == (other.port ?? Self.defaultPort(other.scheme))
    }

    private static func defaultPort(_ scheme: String?) -> Int { scheme?.lowercased() == "http" ? 80 : 443 }

    private static func hostWithoutPort(_ hostPart: String) -> String {
        if hostPart.hasPrefix("[") { return hostPart }
        return hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
