import XCTest
@testable import Syrus

@MainActor
final class HapticsBridgeTests: XCTestCase {
    private final class RecordingPlayer: HapticPlaying {
        var played: [HapticRequest] = []
        func play(_ request: HapticRequest) { played.append(request) }
    }

    private let origin = URL(string: "https://syrus.example.com/review")

    private func makeBridge(clock: @escaping () -> TimeInterval) -> (HapticsBridge, RecordingPlayer) {
        let player = RecordingPlayer()
        let bridge = HapticsBridge(player: player, now: clock)
        bridge.isTrusted = { isMainFrame, url in isMainFrame && url?.host == "syrus.example.com" }
        return (bridge, player)
    }

    // MARK: validation

    func testParsesSelectionAndImpact() {
        XCTAssertEqual(HapticRequest.parse(["v": 1, "kind": "selection"]), .selection)
        XCTAssertEqual(HapticRequest.parse(["v": 1, "kind": "impact", "style": "medium"]), .impact(.medium))
        XCTAssertEqual(HapticRequest.parse(["v": 1, "kind": "impact", "style": "heavy"]), .impact(.heavy))
    }

    func testRejectsMalformedBodies() {
        XCTAssertNil(HapticRequest.parse("selection"))
        XCTAssertNil(HapticRequest.parse(["kind": "selection"]))
        XCTAssertNil(HapticRequest.parse(["v": 2, "kind": "selection"]))
        XCTAssertNil(HapticRequest.parse(["v": true, "kind": "selection"]))
        XCTAssertNil(HapticRequest.parse(["v": 1.5, "kind": "selection"]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "buzz"]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": 4]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "impact"]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "impact", "style": "rigid"]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "impact", "style": 3]))
    }

    func testRejectsUnexpectedKeys() {
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "selection", "duration": 5000]))
        XCTAssertNil(HapticRequest.parse(["v": 1, "kind": "impact", "style": "light", "count": 100]))
    }

    // MARK: trust

    func testUntrustedFramesAndOriginsAreIgnored() {
        let (bridge, player) = makeBridge { 0 }
        let body: [String: Any] = ["v": 1, "kind": "selection"]
        XCTAssertFalse(bridge.handle(body: body, isMainFrame: false, frameURL: origin))
        XCTAssertFalse(bridge.handle(body: body, isMainFrame: true, frameURL: URL(string: "https://evil.example.org/")))
        XCTAssertFalse(bridge.handle(body: body, isMainFrame: true, frameURL: nil))
        XCTAssertTrue(player.played.isEmpty)
    }

    func testDefaultBridgeTrustsNothing() {
        let player = RecordingPlayer()
        let bridge = HapticsBridge(player: player)
        XCTAssertFalse(bridge.handle(body: ["v": 1, "kind": "selection"], isMainFrame: true, frameURL: origin))
        XCTAssertTrue(player.played.isEmpty)
    }

    func testTrustedValidRequestPlays() {
        let (bridge, player) = makeBridge { 0 }
        XCTAssertTrue(bridge.handle(body: ["v": 1, "kind": "impact", "style": "medium"], isMainFrame: true, frameURL: origin))
        XCTAssertEqual(player.played, [.impact(.medium)])
    }

    // MARK: throttle / quantization

    func testSelectionBurstIsThrottled() {
        var time: TimeInterval = 10
        let (bridge, player) = makeBridge { time }
        let body: [String: Any] = ["v": 1, "kind": "selection"]
        XCTAssertTrue(bridge.handle(body: body, isMainFrame: true, frameURL: origin))
        time += 0.01
        XCTAssertFalse(bridge.handle(body: body, isMainFrame: true, frameURL: origin))
        time += HapticThrottle.minimumInterval
        XCTAssertTrue(bridge.handle(body: body, isMainFrame: true, frameURL: origin))
        XCTAssertEqual(player.played.count, 2)
    }

    func testImpactIsRateLimitedAndSuppressesImmediateSelection() {
        var throttle = HapticThrottle()
        XCTAssertTrue(throttle.allows(.impact(.medium), at: 1))
        XCTAssertFalse(throttle.allows(.impact(.medium), at: 1.1))
        XCTAssertFalse(throttle.allows(.selection, at: 1.01))
        XCTAssertTrue(throttle.allows(.selection, at: 1 + HapticThrottle.minimumInterval))
        XCTAssertTrue(throttle.allows(.impact(.medium), at: 1 + HapticThrottle.minimumImpactInterval))
    }
}
