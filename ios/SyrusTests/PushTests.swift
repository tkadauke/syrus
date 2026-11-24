import XCTest
@testable import Syrus

@MainActor
private final class FakePerformer: WebRequestPerforming {
    var statuses: [Int?] = []
    private(set) var requests: [(method: String, path: String, body: [String: Any])] = []

    func send(method: String, path: String, jsonBody: [String: Any]) async throws -> Int? {
        requests.append((method, path, jsonBody))
        return statuses.isEmpty ? 201 : statuses.removeFirst()
    }
}

@MainActor
final class PushTests: XCTestCase {
    private let server = try! ServerURL.parse("https://syrus.example.com")
    private func makeService(token: String? = "abcd") -> PushRegistrationService {
        PushRegistrationService(
            info: .init(bundleID: "app.syrus.ios", apnsEnvironment: "sandbox", deviceName: "Phone", appVersion: "0.1.0", osVersion: "17.0"),
            token: token
        )
    }

    func testTokenIsHexEncoded() {
        XCTAssertEqual(DeviceToken.hexString(from: Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
    }

    func testRegistersOnceThenSkipsWhileUnchanged() async {
        let service = makeService()
        let performer = FakePerformer()

        let first = await service.syncIfNeeded(server: server, via: performer)
        let second = await service.syncIfNeeded(server: server, via: performer)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(performer.requests.count, 1)
        XCTAssertEqual(performer.requests[0].method, "POST")
        XCTAssertEqual(performer.requests[0].path, "/api/v1/app/mobile_devices")
        XCTAssertEqual(performer.requests[0].body["token"] as? String, "abcd")
        XCTAssertEqual(performer.requests[0].body["apns_environment"] as? String, "sandbox")
        XCTAssertEqual(performer.requests[0].body["bundle_id"] as? String, "app.syrus.ios")
    }

    func testRetriesWhenSignedOutOrPageNotReady() async {
        let service = makeService()
        let performer = FakePerformer()
        performer.statuses = [nil, 401, 201]

        let outcomes = [
            await service.syncIfNeeded(server: server, via: performer),
            await service.syncIfNeeded(server: server, via: performer),
            await service.syncIfNeeded(server: server, via: performer),
        ]
        XCTAssertEqual(outcomes, [false, false, true])
        XCTAssertEqual(performer.requests.count, 3)
    }

    func testRotatedTokenAndSwitchedServerReRegister() async throws {
        let service = makeService()
        let performer = FakePerformer()
        _ = await service.syncIfNeeded(server: server, via: performer)
        service.update(token: "ef01")
        _ = await service.syncIfNeeded(server: server, via: performer)
        _ = await service.syncIfNeeded(server: try ServerURL.parse("other.example.com"), via: performer)

        XCTAssertEqual(performer.requests.count, 3)
    }

    func testNoTokenMeansNoRequest() async {
        let performer = FakePerformer()
        let synced = await makeService(token: nil).syncIfNeeded(server: server, via: performer)
        XCTAssertFalse(synced)
        XCTAssertTrue(performer.requests.isEmpty)
    }

    func testUnregisterSendsDeleteWithToken() async {
        let service = makeService()
        let performer = FakePerformer()
        await service.unregister(via: performer)

        XCTAssertEqual(performer.requests.first?.method, "DELETE")
        XCTAssertEqual(performer.requests.first?.path, "/api/v1/app/mobile_devices/unregister")
        XCTAssertEqual(performer.requests.first?.body["token"] as? String, "abcd")
    }

    func testNotificationRouteAcceptsOnlySameOriginPaths() {
        func payload(_ path: Any) -> [AnyHashable: Any] { ["aps": [:], "syrus": ["target_path": path]] }
        XCTAssertEqual(NotificationRoute.targetPath(from: payload("/jobs/12")), "/jobs/12")
        XCTAssertNil(NotificationRoute.targetPath(from: payload("//evil.example.com")))
        XCTAssertNil(NotificationRoute.targetPath(from: payload("https://evil.example.com")))
        XCTAssertNil(NotificationRoute.targetPath(from: payload(42)))
        XCTAssertNil(NotificationRoute.targetPath(from: ["aps": [:]]))
    }
}
