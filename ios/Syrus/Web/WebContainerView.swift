import SwiftUI
import WebKit

/// Hosts the Syrus web UI with loading / error states and server switching.
struct WebContainerView: View {
    let server: ServerURL
    @ObservedObject var model: WebViewModel
    let onSwitchServer: () -> Void
    let onEnableNotifications: () -> Void
    let notificationsStatus: String

    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)

            if case .loading = model.state {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("web-progress")
            }

            if case .failed(let message) = model.state {
                ErrorOverlay(server: server, message: message, retry: model.reload, switchServer: onSwitchServer)
            }
        }
        .overlay(alignment: .topTrailing) { menu }
    }

    private var menu: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
            Button(notificationsStatus, systemImage: "bell", action: onEnableNotifications)
            Divider()
            Text(server.description)
            Button("Switch server", systemImage: "server.rack", role: .destructive, action: onSwitchServer)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .padding(10)
        }
        .accessibilityIdentifier("app-menu")
        .opacity(0.35)
    }
}

private struct ErrorOverlay: View {
    let server: ServerURL
    let message: String
    let retry: () -> Void
    let switchServer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Can’t load Syrus").font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(server.description).font(.footnote.monospaced()).foregroundStyle(.tertiary)
            HStack {
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
                Button("Change server", action: switchServer).buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("web-error")
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        if webView.scrollView.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var webView: WKWebView?

        @objc func refresh(_ control: UIRefreshControl) {
            webView?.reload()
            control.endRefreshing()
        }
    }
}
