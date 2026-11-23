import Foundation
import WebKit

/// Owns the single WKWebView and exposes its loading / error state to SwiftUI.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentURL: URL?

    let webView: WKWebView
    private(set) var policy: NavigationPolicy
    private var progressObservation: NSKeyValueObservation?
    var onPageLoaded: ((WKWebView) -> Void)?

    init(server: URL, configuration: WKWebViewConfiguration? = nil) {
        policy = NavigationPolicy(server: server)
        webView = WKWebView(frame: .zero, configuration: configuration ?? WebViewModel.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = nil
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.progress = view.estimatedProgress }
        }
    }

    /// Persistent default data store keeps the Syrus session cookie across launches.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "SyrusiOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        return config
    }

    func load(_ url: URL? = nil) {
        state = .loading
        webView.load(URLRequest(url: url ?? policy.server))
    }

    func reload() {
        if webView.url == nil { load() } else { state = .loading; webView.reload() }
    }

    /// Opens a path inside the current server (used when a notification is tapped).
    func open(targetPath: String?) {
        if let url = policy.resolve(targetPath: targetPath) { load(url) }
    }

    func switchServer(_ server: URL) {
        policy = NavigationPolicy(server: server)
        webView.stopLoading()
        load()
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let decision = policy.decide(
            for: url,
            isMainFrame: action.targetFrame?.isMainFrame ?? true,
            isUserLink: action.navigationType == .linkActivated
        )
        switch decision {
        case .allow: decisionHandler(.allow)
        case .cancel: decisionHandler(.cancel)
        case .openExternally:
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { state = .loading }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url
        state = .loaded
        onPageLoaded?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    private func fail(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        state = .failed(ns.localizedDescription)
    }
}
