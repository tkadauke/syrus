import XCTest
@testable import Syrus

final class PushTests: XCTestCase {
    private let server = try! ServerURL.parse("https://syrus.example.com/app").get()

    func testHexTokenEncoding() {
        XCTAssertEqual(PushRegistration.hexToken(from: Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
    }

    func testRegistrationBodyMatchesServerContract() {
        let registration = PushRegistration(token: "ab", environment: "sandbox", bundleID: "dev.syrus.ios", deviceName: "Phone", appVersion: "1.0 (1)")
        XCTAssertEqual(registration.jsonBody, [
            "token": "ab", "platform": "ios", "environment": "sandbox",
            "bundle_id": "dev.syrus.ios", "device_name": "Phone", "app_version": "1.0 (1)",
        ])
    }

    func testScriptArgumentsTargetServerAPIWithoutInterpolation() {
        let registration = PushRegistration(token: "ab", environment: "production", bundleID: "b", deviceName: "d", appVersion: "v")
        let register = PushRegistrationScripts.registerArguments(server: server, registration: registration)
        XCTAssertEqual(register["endpoint"] as? String, "https://syrus.example.com/app/api/v1/app/push_devices")
        let unregister = PushRegistrationScripts.unregisterArguments(server: server, token: "ab")
        XCTAssertEqual(unregister["endpoint"] as? String, "https://syrus.example.com/app/api/v1/app/push_devices/destroy_by_token")
        XCTAssertFalse(PushRegistrationScripts.register.contains("ab"))
        XCTAssertTrue(PushRegistrationScripts.register.contains("X-CSRF-Token"))
        XCTAssertTrue(PushRegistrationScripts.unregister.contains("'DELETE'"))
    }

    func testOutcomeFromStatus() {
        XCTAssertEqual(PushRegistrationOutcome(status: 200), .registered)
        XCTAssertEqual(PushRegistrationOutcome(status: 401), .signedOut)
        XCTAssertEqual(PushRegistrationOutcome(status: 422), .failed(422))
    }

    func testPayloadParsingAcceptsOnlyInAppPaths() {
        let ok = PushPayload(userInfo: ["syrus": ["notification_id": 7, "kind": "job_failed", "path": "/jobs/5"]])
        XCTAssertEqual(ok, PushPayload(userInfo: ["syrus": ["notification_id": 7, "kind": "job_failed", "path": "/jobs/5"]]))
        XCTAssertEqual(ok?.path, "/jobs/5")
        XCTAssertEqual(ok?.notificationID, 7)
        XCTAssertNil(PushPayload(userInfo: ["syrus": ["path": "https://evil.example"]])?.path)
        XCTAssertNil(PushPayload(userInfo: ["syrus": ["path": "//evil.example"]])?.path)
        XCTAssertNil(PushPayload(userInfo: ["aps": [:]]))
    }

    func testLoadFailureMessages() {
        XCTAssertEqual(WebLoadFailure.make(from: URLError(.notConnectedToInternet), server: server).title, "You're offline")
        XCTAssertEqual(WebLoadFailure.make(from: URLError(.cannotFindHost), server: server).title, "Server not found")
        XCTAssertEqual(WebLoadFailure.make(from: URLError(.cannotConnectToHost), server: server).title, "Server unreachable")
        XCTAssertEqual(WebLoadFailure.make(from: URLError(.serverCertificateUntrusted), server: server).title, "Secure connection failed")
        XCTAssertEqual(WebLoadFailure.http(status: 502, server: server).message, "syrus.example.com responded with HTTP 502.")
    }
}
