import XCTest
@testable import Syrus

@MainActor
private final class RecordingPlayer: HapticsPlaying {
    var played: [HapticRequest] = []
    func play(_ request: HapticRequest) { played.append(request) }
}

final class HapticsMessageTests: XCTestCase {
    func testAcceptsOnlyTheTwoKnownRequests() {
        XCTAssertEqual(HapticsMessage.parse(["v": 1, "type": "selection"]), .selection)
        XCTAssertEqual(HapticsMessage.parse(["v": 1, "type": "commit"]), .commit)
    }

    func testRejectsMalformedPayloads() {
        XCTAssertNil(HapticsMessage.parse("selection"))
        XCTAssertNil(HapticsMessage.parse(["type": "selection"]))
        XCTAssertNil(HapticsMessage.parse(["v": 2, "type": "selection"]))
        XCTAssertNil(HapticsMessage.parse(["v": "1", "type": "selection"]))
        XCTAssertNil(HapticsMessage.parse(["v": 1, "type": "error"]))
        XCTAssertNil(HapticsMessage.parse(["v": 1, "type": 3]))
        XCTAssertNil(HapticsMessage.parse(["v": 1, "type": "selection", "intensity": 9]))
        XCTAssertNil(HapticsMessage.parse([Any]()))
    }

    func testThrottleDropsBurstsPerKindIndependently() {
        var throttle = HapticsThrottle()
        XCTAssertTrue(throttle.allows(.selection, at: 1.000))
        XCTAssertFalse(throttle.allows(.selection, at: 1.010))
        XCTAssertTrue(throttle.allows(.commit, at: 1.011))
        XCTAssertFalse(throttle.allows(.commit, at: 1.100))
        XCTAssertTrue(throttle.allows(.selection, at: 1.040))
        XCTAssertTrue(throttle.allows(.commit, at: 1.300))
    }
}

@MainActor
final class HapticsBridgeTests: XCTestCase {
    private let server = try! ServerURL.parse("syrus.example.com")
    private let good = ["v": 1, "type": "selection"] as [String: Any]
    private var clock: TimeInterval = 10

    private func bridge(_ player: RecordingPlayer, server: ServerURL?, active: Bool = true) -> HapticsBridge {
        HapticsBridge(player: player, serverProvider: { server }, now: { self.clock }, isActive: { active })
    }

    func testPlaysValidRequestFromTheServerMainFrame() {
        let player = RecordingPlayer()
        let bridge = bridge(player, server: server)
        XCTAssertTrue(bridge.handle(body: good, isMainFrame: true, origin: URL(string: "https://syrus.example.com")))
        XCTAssertEqual(player.played, [.selection])
    }

    func testIgnoresSubframesForeignOriginsAndUnknownServer() {
        let player = RecordingPlayer()
        let bridge = bridge(player, server: server)
        XCTAssertFalse(bridge.handle(body: good, isMainFrame: false, origin: URL(string: "https://syrus.example.com")))
        XCTAssertFalse(bridge.handle(body: good, isMainFrame: true, origin: URL(string: "https://evil.example.com")))
        XCTAssertFalse(bridge.handle(body: good, isMainFrame: true, origin: nil))
        XCTAssertFalse(self.bridge(player, server: nil).handle(body: good, isMainFrame: true, origin: URL(string: "https://syrus.example.com")))
        XCTAssertTrue(player.played.isEmpty)
    }

    func testIgnoresInvalidBodiesAndInactiveApp() {
        let player = RecordingPlayer()
        let origin = URL(string: "https://syrus.example.com")
        XCTAssertFalse(bridge(player, server: server).handle(body: ["v": 1, "type": "x"], isMainFrame: true, origin: origin))
        XCTAssertFalse(bridge(player, server: server, active: false).handle(body: good, isMainFrame: true, origin: origin))
        XCTAssertTrue(player.played.isEmpty)
    }

    func testThrottlesRunawayRequests() {
        let player = RecordingPlayer()
        let bridge = bridge(player, server: server)
        let origin = URL(string: "https://syrus.example.com")
        for _ in 0..<50 { bridge.handle(body: good, isMainFrame: true, origin: origin) }
        XCTAssertEqual(player.played.count, 1)
        clock += 0.05
        bridge.handle(body: good, isMainFrame: true, origin: origin)
        XCTAssertEqual(player.played.count, 2)
    }
}
