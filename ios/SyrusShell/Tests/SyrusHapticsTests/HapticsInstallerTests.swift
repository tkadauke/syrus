#if canImport(WebKit)
import WebKit
import XCTest
@testable import SyrusHaptics

private struct NoopPlayer: HapticPlayer { func play(_ request: HapticRequest) {} }
private struct Enabled: HapticPreferences { var hapticsEnabled = true }

final class HapticsInstallerTests: XCTestCase {
    func testInstallRegistersHandlerAndIsIdempotent() {
        let configuration = WKWebViewConfiguration()
        let bridge = HapticBridge(player: NoopPlayer(), preferences: Enabled())
        let first = HapticsInstaller.install(on: configuration, bridge: bridge) { "example.test" }
        let second = HapticsInstaller.install(on: configuration, bridge: bridge) { "example.test" }
        XCTAssertFalse(first === second)
        XCTAssertEqual(HapticBridge.messageHandlerName, "syrusHaptics")
    }
}
#endif
