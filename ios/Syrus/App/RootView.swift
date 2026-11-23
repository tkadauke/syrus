import SwiftUI

/// Chooses between the connection screen and the web container, and wires web
/// page loads and notification taps to the push coordinator.
struct RootView: View {
    @ObservedObject var store: ServerStore
    @ObservedObject var web: WebController
    @ObservedObject var push: PushCoordinator

    var body: some View {
        Group {
            if let server = store.selected {
                WebContainerView(server: server, controller: web, onSwitchServer: switchServer)
                    .overlay(alignment: .topTrailing) { chrome }
            } else {
                ServerSelectionView(store: store)
            }
        }
        .onAppear { configurePush() }
        .onChange(of: push.deviceToken) { _, _ in registerNow() }
        .onChange(of: push.pendingPath) { _, path in
            guard let path else { return }
            web.open(path: path)
            push.pendingPath = nil
        }
    }

    private var chrome: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise") { web.reload() }
            if web.canGoBack { Button("Back", systemImage: "chevron.left") { web.goBack() } }
            Button("Switch server", systemImage: "server.rack", action: switchServer)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .padding(8)
        }
        .accessibilityIdentifier("app-menu")
        .opacity(0.6)
    }

    private func configurePush() {
        web.onPageLoaded = { server in
            Task { @MainActor in
                await push.requestAuthorizationIfNeeded()
                await push.registerIfPossible(using: web, server: server)
            }
        }
    }

    private func registerNow() {
        guard let server = store.selected else { return }
        Task { await push.registerIfPossible(using: web, server: server) }
    }

    private func switchServer() {
        guard let server = store.selected else { return }
        Task { @MainActor in
            await push.unregister(using: web, server: server)
            web.reset()
            store.disconnect()
        }
    }
}
