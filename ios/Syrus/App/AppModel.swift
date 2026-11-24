import Foundation

/// Composition root shared by SwiftUI views and the UIKit app delegate.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let servers: ServerStore
    let web: WebViewModel
    let push: PushCoordinator

    /// Deep link from a tapped notification, consumed once the web view is ready.
    @Published var pendingPath: String?

    init(servers: ServerStore? = nil, web: WebViewModel? = nil, push: PushCoordinator? = nil) {
        let web = web ?? WebViewModel()
        self.servers = servers ?? ServerStore()
        self.web = web
        self.push = push ?? PushCoordinator()
        web.onPageActivity = { [weak self] in self?.syncPush() }
    }

    func connect() {
        guard let server = servers.selected else { return }
        web.load(server: server, path: pendingPath.take())
    }

    func open(path: String) {
        guard let server = servers.selected else { pendingPath = path; return }
        if let url = server.resolving(path: path) {
            web.load(server: server, path: url.path + (url.query.map { "?\($0)" } ?? ""))
        }
    }

    func syncPush() {
        guard let server = servers.selected else { return }
        Task { await push.service.syncIfNeeded(server: server, via: web) }
    }

    /// Leaves the current server: stop pushes to this device, wipe its session.
    func switchServer() async {
        if let server = servers.selected {
            await push.service.unregister(via: web)
            web.tearDown()
            await web.resetWebsiteData(for: server)
        }
        servers.clearSelection()
    }
}

extension Optional {
    /// Returns the wrapped value and clears the optional.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
