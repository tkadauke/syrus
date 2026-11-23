import SwiftUI
import WebKit

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Hosts the Syrus web app with loading / error overlays and a server switcher.
struct WebShellView: View {
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var push: PushManager
    @StateObject private var model: WebViewModel
    private let server: URL

    init(server: URL) {
        self.server = server
        _model = StateObject(wrappedValue: WebViewModel(server: server))
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(webView: model.webView).ignoresSafeArea(edges: .bottom)
            if case .loading = model.state {
                ProgressView(value: model.progress).progressViewStyle(.linear)
            }
            if case .failed(let message) = model.state {
                ConnectionErrorView(server: server, message: message,
                                    retry: { model.reload() },
                                    changeServer: changeServer)
            }
        }
        .task {
            model.onPageLoaded = { webView in
                Task {
                    await push.requestAuthorizationIfNeeded()
                    await push.syncRegistration(using: webView, server: server)
                }
            }
            model.load()
        }
        .onChange(of: push.pendingTargetPath) { _, path in
            guard let path else { return }
            model.open(targetPath: path)
            push.pendingTargetPath = nil
        }
    }

    private func changeServer() {
        Task {
            await push.unregister(using: model.webView)
            store.clearSelection()
        }
    }
}

struct ConnectionErrorView: View {
    let server: URL
    let message: String
    let retry: () -> Void
    let changeServer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Can't reach Syrus").font(.title3.bold())
            Text(server.absoluteString).font(.footnote.monospaced()).foregroundStyle(.secondary)
            Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
            Button("Change Server", action: changeServer)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("connection-error")
    }
}
