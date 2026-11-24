import SwiftUI
import UIKit
import WebKit

/// Hosts the Syrus web UI with loading / error states and server switching.
struct WebContainerView: View {
    let server: ServerURL
    @ObservedObject var model: WebViewModel
    let onSwitchServer: () -> Void
    let onEnableNotifications: () -> Void
    let onShowDiagnostics: () -> Void
    let notificationsStatus: String

    var body: some View {
        ZStack(alignment: .top) {
            // Only ignore the container (home indicator) area: the keyboard
            // region must still shrink the web view so inputs stay visible.
            WebViewRepresentable(webView: model.webView, isLoading: model.state == .loading)
                .ignoresSafeArea(.container, edges: .bottom)

            if case .loading = model.state {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text("Loading"))
                    .accessibilityValue(Text(model.progress.formatted(.percent.precision(.fractionLength(0)))))
                    .accessibilityIdentifier("web-progress")
            }

            if !model.isOnline, model.state != .failed(WebFailure(kind: .offline)) {
                OfflineBanner()
            }

            if case .failed(let failure) = model.state {
                ErrorOverlay(server: server, failure: failure, retry: model.reload, switchServer: onSwitchServer)
            }
        }
        .overlay(alignment: .topTrailing) { menu }
        .onChange(of: model.state) { _, state in
            if case .failed(let failure) = state {
                UIAccessibility.post(notification: .announcement, argument: failure.spokenSummary)
            }
        }
        .onChange(of: model.isOnline) { _, online in
            UIAccessibility.post(
                notification: .announcement,
                argument: online ? String(localized: "Back online") : String(localized: "You’re offline")
            )
        }
        .sheet(item: $model.completedDownload) { file in
            ShareSheet(url: file.url)
        }
        .alert(
            "Download problem",
            isPresented: Binding(get: { model.downloadError != nil }, set: { if !$0 { model.downloadError = nil } }),
            presenting: model.downloadError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var menu: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
            Button(notificationsStatus, systemImage: "bell", action: onEnableNotifications)
            Button("Diagnostics", systemImage: "stethoscope", action: onShowDiagnostics)
            Divider()
            Text(server.description)
            Button("Switch server", systemImage: "server.rack", role: .destructive, action: onSwitchServer)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .padding(10)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text("Syrus menu"))
        .accessibilityIdentifier("app-menu")
        .opacity(0.6)
    }
}

private struct OfflineBanner: View {
    var body: some View {
        Label("You’re offline. Showing the last loaded page.", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.9))
            .foregroundStyle(.black)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("offline-banner")
    }
}

private struct ErrorOverlay: View {
    let server: ServerURL
    let failure: WebFailure
    let retry: () -> Void
    let switchServer: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: failure.systemImage)
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(failure.source.label)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("web-error-source")
                Text(failure.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(failure.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(server.description).font(.footnote.monospaced()).foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    if failure.retryCanHelp {
                        Button(failure.retryTitle, action: retry)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("web-error-retry")
                    }
                    Button("Change server", action: switchServer)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("web-error-change-server")
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web-error")
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        if webView.scrollView.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Keep the spinner up until the reload really finishes (or fails).
        if !isLoading { uiView.scrollView.refreshControl?.endRefreshing() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var webView: WKWebView?

        @objc func refresh(_ control: UIRefreshControl) {
            webView?.reload()
        }
    }
}
