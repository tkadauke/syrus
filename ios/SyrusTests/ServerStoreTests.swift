import XCTest
@testable import Syrus

@MainActor
final class ServerStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func server(_ input: String) -> ServerURL { try! ServerURL.parse(input).get() }

    func testStartsWithoutSelectionButSuggestsFallback() {
        let store = ServerStore(defaults: defaults, fallback: server("localhost:3000"))
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.suggestion, server("localhost:3000"))
    }

    func testSelectionPersistsAcrossInstances() {
        ServerStore(defaults: defaults, fallback: nil).select(server("a.example.com"))
        let reloaded = ServerStore(defaults: defaults, fallback: nil)
        XCTAssertEqual(reloaded.selected, server("a.example.com"))
        XCTAssertEqual(reloaded.recents, [server("a.example.com")])
    }

    func testRecentsAreMostRecentFirstDedupedAndCapped() {
        let store = ServerStore(defaults: defaults, fallback: nil)
        for index in 1...7 { store.select(server("s\(index).example.com")) }
        store.select(server("s5.example.com"))
        XCTAssertEqual(store.recents.count, ServerStore.maxRecents)
        XCTAssertEqual(store.recents.first, server("s5.example.com"))
        XCTAssertEqual(store.recents.filter { $0 == server("s5.example.com") }.count, 1)
    }

    func testDisconnectKeepsRecentsAndForgetRemovesSelection() {
        let store = ServerStore(defaults: defaults, fallback: nil)
        store.select(server("a.example.com"))
        store.disconnect()
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.recents, [server("a.example.com")])
        XCTAssertNil(ServerStore(defaults: defaults, fallback: nil).selected)

        store.select(server("a.example.com"))
        store.forget(server("a.example.com"))
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.recents.isEmpty)
    }

    func testCorruptStoredValuesAreIgnored() {
        defaults.set("not a url at all ://", forKey: "syrus.server.selected")
        defaults.set(["", "ftp://x"], forKey: "syrus.server.recents")
        let store = ServerStore(defaults: defaults, fallback: nil)
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.recents.isEmpty)
    }
}
