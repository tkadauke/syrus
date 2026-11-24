import Foundation
import WebKit

/// Observable state of the embedded Syrus web view.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentURL: URL?

    let webView: WKWebView
    private(set) var server: ServerURL?
    private var observations: [NSKeyValueObservation] = []

    /// Called after a main-frame load finishes or the URL changes, so push
    /// registration can retry once the user has signed in.
    var onPageActivity: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                let url = view.url
                Task { @MainActor in
                    self?.currentURL = url
                    self?.onPageActivity?()
                }
            },
        ]
    }

    static var userAgentSuffix: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "SyrusiOS/\(version)"
    }

    /// Loads the server (or a deep-link path on it).
    func load(server: ServerURL, path: String? = nil) {
        self.server = server
        let target = path.flatMap { server.resolving(path: $0) } ?? server.url
        state = .loading
        webView.load(URLRequest(url: target))
    }

    func reload() {
        if webView.url == nil, let server { load(server: server) } else { webView.reload() }
    }

    /// Drops cookies and storage for a server the operator is leaving, so the
    /// next server never sees the previous server's session.
    func resetWebsiteData(for server: ServerURL) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let host = server.host
        let matching = records.filter { host == $0.displayName || host.hasSuffix(".\($0.displayName)") }
        await store.removeData(ofTypes: types, for: matching)
    }

    func tearDown() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        server = nil
        state = .idle
        progress = 0
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let server else { return decisionHandler(.cancel) }
        let decision = NavigationPolicy.decide(
            url: navigationAction.request.url,
            server: server,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            isLinkActivation: navigationAction.navigationType == .linkActivated
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally:
            if let url = navigationAction.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .loaded
        onPageActivity?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func fail(with error: Error) {
        let nsError = error as NSError
        // A superseded navigation (e.g. a redirect or link tap mid-load) is not a failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        state = .failed(Self.message(for: nsError))
    }

    static func message(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return String(localized: "You appear to be offline.")
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            return String(localized: "Couldn’t reach the Syrus server. Check the address and your network.")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorSecureConnectionFailed:
            return String(localized: "The server’s certificate isn’t trusted.")
        default:
            return error.localizedDescription
        }
    }
}

extension WebViewModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank: stay in the single web view unless it leaves the server.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let server, server.sameOrigin(as: url) { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(message: message, actions: [("OK", .default, completionHandler)])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(message: message, actions: [
            ("Cancel", .cancel, { completionHandler(false) }),
            ("OK", .default, { completionHandler(true) }),
        ])
    }

    private func present(message: String, actions: [(String, UIAlertAction.Style, () -> Void)]) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        for (title, style, handler) in actions {
            alert.addAction(UIAlertAction(title: title, style: style) { _ in handler() })
        }
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        if let top { top.present(alert, animated: true) } else { actions.last?.2() }
    }
}
