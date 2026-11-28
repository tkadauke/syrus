import Foundation
import WebKit

/// Observable state of the embedded Syrus web view.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(WebFailure)
    }

    /// A file the web app asked the system to download, ready to be shared/saved.
    struct DownloadedFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    /// Seconds before a main-frame request is considered timed out.
    static let requestTimeout: TimeInterval = 30

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentURL: URL?
    @Published private(set) var isOnline = true
    @Published var completedDownload: DownloadedFile?
    @Published var downloadError: String?

    let webView: WKWebView
    private(set) var server: ServerURL?
    private var observations: [NSKeyValueObservation] = []
    private let network: NetworkMonitor?
    private var consecutiveContentCrashes = 0
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    let haptics: HapticsBridge

    /// Called after a main-frame load finishes or the URL changes, so push
    /// registration can retry once the user has signed in.
    var onPageActivity: (() -> Void)?

    init(monitorsNetwork: Bool = true) {
        network = monitorsNetwork ? NetworkMonitor() : nil
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        let haptics = HapticsBridge()
        self.haptics = haptics
        configuration.userContentController.add(WeakScriptMessageHandler(haptics), name: HapticRequest.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        haptics.isTrusted = { [weak self] isMainFrame, url in
            guard isMainFrame, let url, let server = self?.server else { return false }
            return server.sameOrigin(as: url)
        }

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

        network?.onChange = { [weak self] online in self?.connectivityChanged(isOnline: online) }
        network?.start()
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
        webView.load(URLRequest(url: target, timeoutInterval: Self.requestTimeout))
    }

    /// Retry after a failure. Reloads the current page when there is one;
    /// otherwise (or after the session expired) starts over at the server root.
    func reload() {
        guard let server else { return }
        if webView.url == nil || webView.url?.absoluteString == "about:blank" || isAuthExpired {
            load(server: server)
        } else {
            state = .loading
            webView.reload()
        }
    }

    private var isAuthExpired: Bool {
        if case .failed(let failure) = state, case .authExpired = failure.kind { return true }
        return false
    }

    // MARK: - State transitions (also driven directly by unit tests)

    func fail(with error: Error) {
        let nsError = error as NSError
        // A superseded navigation (e.g. a redirect or link tap mid-load) is not a failure.
        if WebFailure.isCancellation(nsError) { return }
        // Frame-load-interrupted: the navigation became a download or was handled elsewhere.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        state = .failed(WebFailure.classify(nsError))
    }

    func connectivityChanged(isOnline online: Bool) {
        let regained = online && !isOnline
        isOnline = online
        guard regained, case .failed(let failure) = state, failure.retriesWhenOnline else { return }
        reload()
    }

    /// Called when the app returns to the foreground: recovers from a web view
    /// that lost its content while suspended and retries recoverable failures.
    func resume() {
        guard let server else { return }
        switch state {
        case .failed(let failure):
            if failure.retriesWhenOnline && isOnline { reload() }
        case .idle, .loaded:
            if webView.url == nil || webView.url?.absoluteString == "about:blank" { load(server: server) }
        case .loading:
            break
        }
    }

    func contentProcessTerminated() {
        consecutiveContentCrashes += 1
        if consecutiveContentCrashes > 1 || webView.url == nil {
            state = .failed(WebFailure(kind: .contentCrashed))
        } else {
            state = .loading
            webView.reload()
        }
    }

    func mainFrameResponded(statusCode: Int) {
        if let failure = WebFailure.classify(statusCode: statusCode) { state = .failed(failure) }
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
        consecutiveContentCrashes = 0
        completedDownload = nil
        downloadError = nil
    }
}

/// WKUserContentController retains its handlers strongly; this avoids a cycle
/// through the web view that owns the controller.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
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
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally:
            if let url = navigationAction.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let http = navigationResponse.response as? HTTPURLResponse
        let isAttachment = http?.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().hasPrefix("attachment") ?? false
        if isAttachment || !navigationResponse.canShowMIMEType {
            return decisionHandler(.download)
        }
        if navigationResponse.isForMainFrame, let status = http?.statusCode,
           WebFailure.classify(statusCode: status) != nil {
            mainFrameResponded(statusCode: status)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        consecutiveContentCrashes = 0
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
        contentProcessTerminated()
    }
}

extension WebViewModel: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Each download gets its own directory so identical names never collide.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = (suggestedFilename as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            downloadError = String(localized: "Couldn’t save the download: \(error.localizedDescription)")
            return completionHandler(nil)
        }
        let destination = directory.appendingPathComponent(name.isEmpty ? "download" : name)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        completedDownload = DownloadedFile(url: url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        downloadError = String(localized: "The download failed: \(error.localizedDescription)")
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
