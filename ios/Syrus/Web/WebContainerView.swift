import SwiftUI

/// The connected state: Syrus content with a thin native chrome for progress,
/// errors, reload and switching servers.
struct WebContainerView: View {
    let server: ServerURL
    @ObservedObject var controller: WebController
    let onSwitchServer: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            SyrusWebView(controller: controller)
                .ignoresSafeArea(edges: .bottom)

            if case .loading(let progress) = controller.state {
                ProgressView(value: max(progress, 0.05))
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("web-progress")
            }

            if case .failed(let failure) = controller.state {
                WebErrorView(
                    failure: failure,
                    server: server,
                    onRetry: controller.reload,
                    onSwitchServer: onSwitchServer
                )
            }
        }
        .onAppear { controller.load(server: server) }
        .onChange(of: server) { _, newValue in controller.load(server: newValue) }
    }
}

struct WebErrorView: View {
    let failure: WebLoadFailure
    let server: ServerURL
    let onRetry: () -> Void
    let onSwitchServer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(failure.title).font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(server.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retry-button")
                Button("Change server", action: onSwitchServer)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("change-server-button")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web-error")
    }
}
