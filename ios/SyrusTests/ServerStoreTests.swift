import XCTest
@testable import Syrus

@MainActor
final class ServerStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "syrus.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSelectionPersistsAcrossInstances() throws {
        let server = try ServerURL.parse("syrus.example.com")
        ServerStore(defaults: defaults).select(server)

        let reloaded = ServerStore(defaults: defaults)
        XCTAssertEqual(reloaded.selected, server)
        XCTAssertEqual(reloaded.recent, [server])
    }

    func testRecentIsMostRecentFirstDedupedAndCapped() throws {
        let store = ServerStore(defaults: defaults)
        for index in 1...7 { store.select(try ServerURL.parse("s\(index).example.com")) }
        store.select(try ServerURL.parse("s5.example.com"))

        XCTAssertEqual(store.recent.count, ServerStore.maxRecent)
        XCTAssertEqual(store.recent.first?.host, "s5.example.com")
        XCTAssertEqual(Set(store.recent).count, store.recent.count)
    }

    func testClearSelectionKeepsRecentButForgetRemovesIt() throws {
        let server = try ServerURL.parse("syrus.example.com")
        let store = ServerStore(defaults: defaults)
        store.select(server)
        store.clearSelection()
        XCTAssertNil(ServerStore(defaults: defaults).selected)
        XCTAssertEqual(store.recent, [server])

        store.forget(server)
        XCTAssertTrue(ServerStore(defaults: defaults).recent.isEmpty)
    }

    func testLaunchArgumentOverridesStoredSelection() throws {
        ServerStore(defaults: defaults).select(try ServerURL.parse("old.example.com"))
        defaults.set("http://localhost:3000", forKey: ServerStore.launchOverrideKey)

        XCTAssertEqual(ServerStore(defaults: defaults).selected?.description, "http://localhost:3000")
    }
}
