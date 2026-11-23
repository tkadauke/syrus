import XCTest
import UserNotifications
@testable import Syrus

@MainActor
final class PushTests: XCTestCase {
    func testHexEncodesDeviceToken() {
        XCTAssertEqual(PushRegistration.hexString(from: Data([0x0a, 0xff, 0x01])), "0aff01")
    }

    func testRegistrationBodyMatchesServerContract() {
        let body = PushRegistration(token: "ab", environment: "sandbox", bundleID: "estate.syrus.app",
                                    deviceName: "Phone", appVersion: "1").registerBody
        XCTAssertEqual(body["platform"], "ios")
        XCTAssertEqual(body["token"], "ab")
        XCTAssertEqual(body["environment"], "sandbox")
        XCTAssertEqual(PushRegistration.path, "/api/v1/app/push_devices")
    }

    func testTokenIsStoredOnRegistrationAndResetsRegisteredMarker() {
        let suite = "PushTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["marker": "x"], forKey: PushManager.registeredKey)
        let manager = PushManager(defaults: defaults)

        manager.didRegister(deviceToken: Data([0xde, 0xad]))

        XCTAssertEqual(manager.deviceToken, "dead")
        XCTAssertNil(defaults.dictionary(forKey: PushManager.registeredKey))
    }

    func testTargetPathExtraction() {
        XCTAssertEqual(PushManager.targetPath(from: ["target_path": "/jobs/3"]), "/jobs/3")
        XCTAssertNil(PushManager.targetPath(from: [:]))
    }

    func testAuthorizationMapping() {
        XCTAssertEqual(PushManager.map(.notDetermined), .notDetermined)
        XCTAssertEqual(PushManager.map(.denied), .denied)
        XCTAssertEqual(PushManager.map(.authorized), .authorized)
    }
}
