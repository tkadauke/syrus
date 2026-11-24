import XCTest
@testable import SyrusHaptics

private final class RecordingPlayer: HapticPlayer {
    var played: [HapticRequest] = []
    func play(_ request: HapticRequest) { played.append(request) }
}

private struct Prefs: HapticPreferences { var hapticsEnabled: Bool }

final class HapticBridgeTests: XCTestCase {
    private var now: TimeInterval = 100
    private let selection: [String: Any] = ["v": 1, "kind": "selection"]
    private let impact: [String: Any] = ["v": 1, "kind": "impact", "style": "medium"]

    private func makeBridge(enabled: Bool = true, player: RecordingPlayer) -> HapticBridge {
        HapticBridge(player: player, preferences: Prefs(hapticsEnabled: enabled), clock: { self.now })
    }

    func testPlaysValidRequestsAndDropsInvalidOnes() {
        let player = RecordingPlayer()
        let bridge = makeBridge(player: player)
        XCTAssertTrue(bridge.handle(selection))
        XCTAssertFalse(bridge.handle(["v": 1, "kind": "boom"]))
        XCTAssertEqual(player.played, [.selection])
    }

    func testSelectionBurstsAreQuantizedByTheThrottle() {
        let player = RecordingPlayer()
        let bridge = makeBridge(player: player)
        for _ in 0..<10 { bridge.handle(selection); now += 0.005 } // 50ms total, 30ms interval
        XCTAssertEqual(player.played.count, 2)
        now += 1
        XCTAssertTrue(bridge.handle(selection))
    }

    func testCommitImpactIsNotSuppressedByRecentSelection() {
        let player = RecordingPlayer()
        let bridge = makeBridge(player: player)
        bridge.handle(selection)
        XCTAssertTrue(bridge.handle(impact))
        XCTAssertFalse(bridge.handle(impact), "duplicate impacts inside the impact interval are dropped")
        XCTAssertEqual(player.played, [.selection, .impact(.medium)])
    }

    func testDisabledPreferencesPlayNothing() {
        let player = RecordingPlayer()
        let bridge = makeBridge(enabled: false, player: player)
        XCTAssertFalse(bridge.handle(selection))
        XCTAssertFalse(bridge.handle(impact))
        XCTAssertTrue(player.played.isEmpty)
    }
}
