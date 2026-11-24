import Combine
import Foundation

/// Persists which Syrus server the app talks to, plus recently used servers.
///
/// Storage is `UserDefaults` (non-secret configuration only; session cookies
/// live in the web view's persistent data store). Passing `-SyrusServerURL
/// https://…` as a launch argument (or setting it in an Xcode scheme) seeds the
/// selection for development and UI automation.
@MainActor
final class ServerStore: ObservableObject {
    static let selectedKey = "syrus.server.selected"
    static let recentKey = "syrus.server.recent"
    static let launchOverrideKey = "SyrusServerURL"
    static let maxRecent = 5

    /// Suggested value for the connection screen in debug builds.
    static var developmentDefault: String? {
        #if DEBUG
        return "http://localhost:3000"
        #else
        return nil
        #endif
    }

    @Published private(set) var selected: ServerURL?
    @Published private(set) var recent: [ServerURL]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        recent = defaults.data(forKey: Self.recentKey).flatMap { try? decoder.decode([ServerURL].self, from: $0) } ?? []

        if let override = defaults.string(forKey: Self.launchOverrideKey), let server = try? ServerURL.parse(override) {
            selected = server
            remember(server)
        } else {
            selected = defaults.data(forKey: Self.selectedKey).flatMap { try? decoder.decode(ServerURL.self, from: $0) }
        }
    }

    func select(_ server: ServerURL) {
        selected = server
        remember(server)
        persistSelection()
    }

    /// Returns to the connection screen without forgetting the server list.
    func clearSelection() {
        selected = nil
        persistSelection()
    }

    func forget(_ server: ServerURL) {
        recent.removeAll { $0 == server }
        if selected == server { selected = nil }
        persistSelection()
        persistRecent()
    }

    private func remember(_ server: ServerURL) {
        recent.removeAll { $0 == server }
        recent.insert(server, at: 0)
        if recent.count > Self.maxRecent { recent = Array(recent.prefix(Self.maxRecent)) }
        persistRecent()
    }

    private func persistSelection() {
        if let selected, let data = try? JSONEncoder().encode(selected) {
            defaults.set(data, forKey: Self.selectedKey)
        } else {
            defaults.removeObject(forKey: Self.selectedKey)
        }
    }

    private func persistRecent() {
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: Self.recentKey) }
    }
}
