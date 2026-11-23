import Foundation

/// Persistent server configuration: the active server plus recently used ones.
struct ServerConfiguration: Codable, Equatable {
    var selected: URL?
    var recents: [URL] = []
}

@MainActor
final class ServerStore: ObservableObject {
    static let maxRecents = 5
    static let storageKey = "syrus.server.configuration.v1"
    /// Development default so a simulator can reach a Rails server on the host Mac.
    static let developmentDefault = URL(string: "http://localhost:3000")!

    @Published private(set) var configuration: ServerConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(ServerConfiguration.self, from: data) {
            configuration = stored
        } else {
            configuration = ServerConfiguration()
        }
    }

    var selected: URL? { configuration.selected }

    /// Suggestions shown on the connection screen (recents, then the dev default).
    var suggestions: [URL] {
        var list = configuration.recents
        #if DEBUG
        if !list.contains(Self.developmentDefault) { list.append(Self.developmentDefault) }
        #endif
        return list
    }

    func select(_ url: URL) {
        configuration.selected = url
        configuration.recents.removeAll { $0 == url }
        configuration.recents.insert(url, at: 0)
        configuration.recents = Array(configuration.recents.prefix(Self.maxRecents))
        persist()
    }

    /// Returns to the connection screen without forgetting recents.
    func clearSelection() {
        configuration.selected = nil
        persist()
    }

    func forget(_ url: URL) {
        configuration.recents.removeAll { $0 == url }
        if configuration.selected == url { configuration.selected = nil }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
