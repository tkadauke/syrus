import Combine
import UIKit
import WebKit

/// Owns the `WKWebView` that renders Syrus and is the boundary for navigation,
/// loading/error state, and server switching. SwiftUI hosts the view through
/// `SyrusWebView`; everything WebKit-specific stays in this file.
@MainActor
final class WebController: NSObject, ObservableObject, WebScriptRunner {
    @Published private(set) var state: WebLoadState = .idle
    @Published private(set) var canGoBack = false
    @Published private(set) var currentURL: URL?

    let webView: WKWebView
    private(set) var server: ServerURL?
    /// Invoked after each successful main-frame load on the server's origin.
    var onPageLoaded: ((ServerURL) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration? = nil) {
        webView = WKWebView(frame: .zero, configuration: configuration ?? WebController.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, case .loading = self.state else { return }
                    self.state = .loading(progress: web.estimatedProgress)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.currentURL = web.url }
            },
        ]
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Persistent store: the Syrus session cookie must survive relaunches.
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "SyrusiOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
        return configuration
    }

    /// Loads `server`'s root. Switching servers resets history so Back never
    /// crosses origins.
    func load(server: ServerURL) {
        guard self.server != server else { return }
        self.server = server
        state = .loading(progress: 0)
        webView.load(URLRequest(url: server.url))
    }

    func open(path: String) {
        guard let server, let url = server.resolving(path: path) else { return }
        state = .loading(progress: 0)
        webView.load(URLRequest(url: url))
    }

    func reload() {
        state = .loading(progress: 0)
        if webView.url != nil {
            webView.reload()
        } else if let server {
            webView.load(URLRequest(url: server.url))
        }
    }

    func goBack() { webView.goBack() }

    /// Forget the current server and blank the view (used when switching).
    func reset() {
        server = nil
        state = .idle
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func runScript(_ script: String, arguments: [String: Any]) async -> Int? {
        do {
            let result = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            return (result as? NSNumber)?.intValue
        } catch {
            return nil
        }
    }

    private func fail(_ error: Error) {
        guard let server else { return }
        // A cancelled navigation (redirect, new request) isn't a failure.
        if (error as? URLError)?.code == .cancelled { return }
        state = .failed(.make(from: error, server: server))
    }
}

extension WebController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let server else { return .cancel }
        let decision = NavigationPolicy(server: server)
            .decision(for: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
        switch decision {
        case .allow:
            return .allow
        case .openExternally:
            if let url = navigationAction.request.url { await UIApplication.shared.open(url) }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 500,
           let server {
            state = .failed(.http(status: http.statusCode, server: server))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if case .failed = state { return }
        state = .loading(progress: webView.estimatedProgress)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .loaded
        if let server, let url = webView.url, server.isSameOrigin(as: url) {
            onPageLoaded?(server)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
}

extension WebController: WKUIDelegate {
    /// `target=_blank` links: stay in the app for Syrus pages, otherwise leave.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let server, server.isSameOrigin(as: url) {
            webView.load(URLRequest(url: url))
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await present(message: message, confirmTitle: "OK", cancelTitle: nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await present(message: message, confirmTitle: "OK", cancelTitle: "Cancel")
    }

    private func present(message: String, confirmTitle: String, cancelTitle: String?) async -> Bool {
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first
        else { return false }
        var top = presenter
        while let next = top.presentedViewController { top = next }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { _ in continuation.resume(returning: true) })
            if let cancelTitle {
                alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in continuation.resume(returning: false) })
            }
            top.present(alert, animated: true)
        }
    }
}
