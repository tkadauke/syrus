import Foundation

/// Decides which navigations stay inside the app's web view.
struct NavigationPolicy: Equatable {
    enum Decision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    let server: URL

    func decide(for url: URL, isMainFrame: Bool, isUserLink: Bool) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .cancel }
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        guard scheme == "http" || scheme == "https" else {
            // mailto:, tel:, custom app schemes: hand to the system, only on user taps.
            return isUserLink ? .openExternally : .cancel
        }
        if isSameOrigin(url) { return .allow }
        // Third-party content inside subframes (embeds) is allowed; top-level
        // user navigation off the Syrus origin (e.g. a GitHub link) opens in Safari.
        if !isMainFrame { return .allow }
        return isUserLink ? .openExternally : .allow
    }

    func isSameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == server.scheme?.lowercased()
            && url.host?.lowercased() == server.host?.lowercased()
            && (url.port ?? defaultPort(url)) == (server.port ?? defaultPort(server))
    }

    private func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }

    /// Resolves a server-relative notification `target_path` against the server.
    func resolve(targetPath: String?) -> URL? {
        guard let path = targetPath, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(string: path, relativeTo: server)?.absoluteURL
    }
}
