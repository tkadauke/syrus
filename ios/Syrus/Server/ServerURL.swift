import Foundation

/// Parsing and normalisation for operator-entered Syrus server addresses.
enum ServerURL {
    enum ParseError: Error, Equatable {
        case empty
        case invalid
        case unsupportedScheme
    }

    /// Accepts `syrus.example.com`, `localhost:3000`, or a full URL. A missing
    /// scheme defaults to https, except for loopback / LAN hosts which default
    /// to http (development servers rarely have certificates).
    static func parse(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let candidate = trimmed.contains("://") ? trimmed : "\(defaultScheme(for: trimmed))://\(trimmed)"
        guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else {
            throw ParseError.invalid
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ParseError.unsupportedScheme
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        guard let url = components.url else { throw ParseError.invalid }
        return url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private static func defaultScheme(for input: String) -> String {
        let host = input.split(separator: "/").first.map(String.init) ?? input
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return isLocalHost(bare) ? "http" : "https"
    }
}
