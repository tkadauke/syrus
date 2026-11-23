import Foundation

/// Persistent server configuration: the currently selected Syrus server plus a
/// short most-recently-used list. Backed by `UserDefaults` (injectable for
/// tests); nothing secret lives here — authentication is the web session.
@MainActor
final class ServerStore: ObservableObject {
    static let maxRecents = 5

    /// The development default: the Rails dev server as seen from the
    /// simulator (which shares the host's network). Release builds start with
    /// no server so the operator is always asked.
    nonisolated static var defaultDevelopmentServer: ServerURL? {
        #if DEBUG
        return try? ServerURL.parse("http://localhost:3000").get()
        #else
        return nil
        #endif
    }

    @Published private(set) var selected: ServerURL?
    @Published private(set) var recents: [ServerURL]

    private let defaults: UserDefaults
    private let selectedKey = "syrus.server.selected"
    private let recentsKey = "syrus.server.recents"

    init(defaults: UserDefaults = .standard, fallback: ServerURL? = ServerStore.defaultDevelopmentServer) {
        self.defaults = defaults
        let storedRecents = (defaults.stringArray(forKey: recentsKey) ?? []).compactMap(ServerStore.decode)
        self.recents = storedRecents
        if let raw = defaults.string(forKey: selectedKey) {
            self.selected = ServerStore.decode(raw)
        } else {
            // The fallback is only a suggestion until the operator connects.
            self.selected = nil
        }
        self.suggestion = fallback
    }

    /// Pre-filled value for the connection screen when nothing is selected.
    let suggestion: ServerURL?

    func select(_ server: ServerURL) {
        selected = server
        defaults.set(server.absoluteString, forKey: selectedKey)
        recents = ([server] + recents.filter { $0 != server }).prefix(Self.maxRecents).map { $0 }
        defaults.set(recents.map(\.absoluteString), forKey: recentsKey)
    }

    /// Returns to the connection screen without forgetting recents.
    func disconnect() {
        selected = nil
        defaults.removeObject(forKey: selectedKey)
    }

    func forget(_ server: ServerURL) {
        recents.removeAll { $0 == server }
        defaults.set(recents.map(\.absoluteString), forKey: recentsKey)
        if selected == server { disconnect() }
    }

    private static func decode(_ raw: String) -> ServerURL? {
        try? ServerURL.parse(raw).get()
    }
}
