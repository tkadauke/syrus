import Foundation
import WebKit

/// Decides what the embedded web view may navigate to.
///
/// * Same-origin navigations stay in the app.
/// * Cross-origin *link taps* in the main frame (docs, GitHub PR links, …)
///   open in the system browser.
/// * Cross-origin redirects and form posts stay in-app so sign-in flows that
///   bounce through an identity provider keep working.
/// * Non-web schemes (`mailto:`, `tel:`, …) are handed to the system.
enum NavigationPolicy {
    enum Decision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    static func decide(url: URL?, server: ServerURL, isMainFrame: Bool, isLinkActivation: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "about", "blob", "data":
            return .allow
        case "http", "https":
            if server.sameOrigin(as: url) || !isMainFrame { return .allow }
            return isLinkActivation ? .openExternally : .allow
        default:
            return .openExternally
        }
    }
}
