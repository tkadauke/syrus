import Foundation

/// Decides what to do with a navigation request from the Syrus web view.
/// Kept free of WebKit types so it is trivially unit-testable.
enum NavigationDecision: Equatable {
    /// Load inside the web view.
    case allow
    /// Hand to the system (Safari, Mail, …) and cancel in-app navigation.
    case openExternally
    /// Not loadable at all (e.g. `javascript:`).
    case cancel
}

struct NavigationPolicy {
    let server: ServerURL

    func decision(for url: URL?, isMainFrame: Bool) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "about", "blob", "data":
            return .allow
        case "http", "https":
            if server.isSameOrigin(as: url) { return .allow }
            // Cross-origin subframes (embeds) may load; top-level cross-origin
            // navigation leaves the app so the web view stays on Syrus.
            return isMainFrame ? .openExternally : .allow
        case "mailto", "tel":
            return .openExternally
        default:
            return .cancel
        }
    }
}
