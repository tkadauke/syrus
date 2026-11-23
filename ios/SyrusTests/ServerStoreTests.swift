import XCTest
@testable import Syrus

@MainActor
final class ServerStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "ServerStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSelectionPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let url = URL(string: "https://syrus.example.com")!
        ServerStore(defaults: defaults).select(url)
        XCTAssertEqual(ServerStore(defaults: defaults).selected, url)
    }

    func testRecentsAreDeduplicatedAndCapped() {
        let store = ServerStore(defaults: makeDefaults())
        for i in 0..<7 { store.select(URL(string: "https://s\(i).example.com")!) }
        store.select(URL(string: "https://s6.example.com")!)
        XCTAssertEqual(store.configuration.recents.count, ServerStore.maxRecents)
        XCTAssertEqual(store.configuration.recents.first?.host, "s6.example.com")
    }

    func testClearSelectionKeepsRecents() {
        let store = ServerStore(defaults: makeDefaults())
        let url = URL(string: "https://syrus.example.com")!
        store.select(url)
        store.clearSelection()
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.configuration.recents, [url])
    }

    func testForgetRemovesAndDeselects() {
        let store = ServerStore(defaults: makeDefaults())
        let url = URL(string: "https://syrus.example.com")!
        store.select(url)
        store.forget(url)
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.configuration.recents.isEmpty)
    }
}
