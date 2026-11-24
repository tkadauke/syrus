import UserNotifications
import XCTest
@testable import Syrus

@MainActor
private final class FakePerformer: WebRequestPerforming {
    var statuses: [Int?] = []
    /// Bodies returned alongside statuses, in order; missing entries mean "".
    var bodies: [String] = []
    private(set) var requests: [(method: String, path: String, body: [String: Any])] = []

    func perform(method: String, path: String, jsonBody: [String: Any]) async throws -> WebResponse? {
        requests.append((method, path, jsonBody))
        let status = statuses.isEmpty ? 201 : statuses.removeFirst()
        let body = bodies.isEmpty ? "" : bodies.removeFirst()
        return status.map { WebResponse(status: $0, body: body) }
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

    // MARK: Diagnostics

    func testSyncOutcomesDistinguishFailureStates() async {
        let service = makeService()
        let performer = FakePerformer()
        performer.statuses = [nil, 401, 500, 201]
        var seen: [PushRegistrationService.SyncOutcome] = []
        for _ in 0..<4 {
            _ = await service.syncIfNeeded(server: server, via: performer)
            seen.append(service.lastSync)
        }
        XCTAssertEqual(seen, [.pageNotReady, .signedOut(401), .failed(500), .synced])
        let tokenless = makeService(token: nil)
        _ = await tokenless.syncIfNeeded(server: server, via: performer)
        XCTAssertEqual(tokenless.lastSync, .noToken)
    }

    func testLogoutInvalidationUnregistersAndForcesReRegistration() async {
        let service = makeService()
        let performer = FakePerformer()
        _ = await service.syncIfNeeded(server: server, via: performer)
        await service.unregister(via: performer)
        XCTAssertEqual(service.lastSync, .notAttempted)
        _ = await service.syncIfNeeded(server: server, via: performer)
        XCTAssertEqual(performer.requests.map(\.method), ["POST", "DELETE", "POST"])
    }

    func testServerSwitchRegistersAgainstNewServerOnly() async throws {
        let service = makeService()
        let performer = FakePerformer()
        let other = try ServerURL.parse("other.example.com")
        _ = await service.syncIfNeeded(server: server, via: performer)
        await service.unregister(via: performer)
        _ = await service.syncIfNeeded(server: other, via: performer)
        XCTAssertEqual(performer.requests.map(\.method), ["POST", "DELETE", "POST"])
        XCTAssertEqual(service.lastSync, .synced)
    }

    func testTokenIsRedacted() {
        let token = String(repeating: "ab", count: 32)
        let redacted = DeviceToken.redacted(token)
        XCTAssertFalse(redacted.contains(token))
        XCTAssertEqual(redacted, "…ababab (64 chars)")
        XCTAssertEqual(DeviceToken.redacted(nil), "—")
    }

    func testProbeParsesDevicesAndStates() async {
        let service = makeService(token: "00112233aabbcc")
        let performer = FakePerformer()
        performer.statuses = [200, 401, nil, 500]
        performer.bodies = [
            #"{"apns_configured":true,"mobile_devices":[{"id":4,"apns_environment":"sandbox","token_suffix":"aabbcc","disabled_at":null,"disabled_reason":null}]}"#,
        ]
        let signedIn = await service.probeServer(via: performer)
        guard case .signedIn(let state) = signedIn else { return XCTFail("expected signed in, got \(signedIn)") }
        XCTAssertTrue(state.apnsConfigured)
        XCTAssertEqual(state.device(matching: "00112233aabbcc")?.id, 4)
        XCTAssertNil(state.device(matching: "ffffff"))
        XCTAssertEqual(performer.requests.first?.method, "GET")

        let signedOut = await service.probeServer(via: performer)
        let notReady = await service.probeServer(via: performer)
        let failed = await service.probeServer(via: performer)
        XCTAssertEqual(signedOut, .signedOut)
        XCTAssertEqual(notReady, .pageNotReady)
        XCTAssertEqual(failed, .failed(500))
    }

    func testTestNotificationOutcomes() async {
        let service = makeService(token: "abcd")
        let performer = FakePerformer()
        performer.statuses = [200, 200, 200, 503, 422, 401, nil, 500]
        performer.bodies = [
            #"{"delivered":1,"target_path":"/notifications","results":[]}"#,
            #"{"delivered":0,"results":[{"outcome":"token_rejected","reason":"BadDeviceToken"}]}"#,
            #"{"delivered":0,"results":[{"outcome":"failed","reason":"TooManyRequests"}]}"#,
            #"{"error":{"code":"apns_not_configured"}}"#,
            #"{"error":{"code":"no_registered_device"}}"#,
            "", "", "",
        ]
        var outcomes: [TestPushOutcome] = []
        for _ in 0..<8 { outcomes.append(await service.sendTestNotification(via: performer)) }

        XCTAssertEqual(outcomes, [
            .sent(deepLink: "/notifications"),
            .tokenRejected("BadDeviceToken"),
            .failed("TooManyRequests"),
            .apnsNotConfigured,
            .noRegisteredDevice,
            .signedOut,
            .pageNotReady,
            .failed("HTTP 500"),
        ])
        XCTAssertEqual(performer.requests[0].path, "/api/v1/app/mobile_devices/test_notification")
        XCTAssertEqual(performer.requests[0].body["token"] as? String, "abcd")
    }

    func testRouteOutcomesAndEventLog() {
        func payload(_ path: Any?, kind: String? = nil) -> [AnyHashable: Any] {
            var syrus: [String: Any] = [:]
            if let path { syrus["target_path"] = path }
            if let kind { syrus["kind"] = kind }
            return ["syrus": syrus]
        }
        XCTAssertEqual(NotificationRoute.outcome(from: payload("/notifications", kind: "test")), .path("/notifications"))
        XCTAssertEqual(NotificationRoute.outcome(from: payload(nil)), .noTarget)
        XCTAssertEqual(NotificationRoute.outcome(from: ["aps": [:]]), .noTarget)
        XCTAssertEqual(NotificationRoute.outcome(from: payload("//evil.example.com")), .rejected("//evil.example.com"))
        XCTAssertEqual(NotificationRoute.kind(from: payload("/x", kind: "test")), "test")

        var log = PushEventLog()
        log.pushReceived(userInfo: payload("/notifications", kind: "test"), foreground: false)
        log.deepLink(.path("/notifications"))
        XCTAssertEqual(log.lastPush?.summary, "test (tapped)")
        XCTAssertEqual(log.lastDeepLink?.summary, "opened /notifications")
        log.deepLink(.rejected("https://evil.example.com"))
        XCTAssertTrue(log.lastDeepLink?.summary.hasPrefix("rejected") == true)
        log.registrationFailed("no entitlement")
        XCTAssertEqual(log.registrationError?.summary, "no entitlement")
        log.registrationSucceeded()
        XCTAssertNil(log.registrationError)
    }

    private func input(
        token: String? = "00112233aabbcc",
        auth: UNAuthorizationStatus = .authorized,
        sync: PushRegistrationService.SyncOutcome = .synced,
        probe: ServerProbe = .notChecked
    ) -> DiagnosticsInput {
        DiagnosticsInput(
            server: server, authorization: auth, token: token, apnsEnvironment: "sandbox", bundleID: "app.syrus.ios",
            appVersion: "0.1.0", buildNumber: "7", sync: sync, probe: probe, events: PushEventLog()
        )
    }

    private func row(_ title: String, _ input: DiagnosticsInput) -> DiagnosticsRow {
        DiagnosticsReport.rows(for: input).first { $0.title == title }!
    }

    func testReportNeverShowsFullTokenOrSecrets() {
        let rows = DiagnosticsReport.rows(for: input())
        XCTAssertFalse(rows.contains { $0.value.contains("00112233aabbcc") })
        XCTAssertEqual(row("APNs token", input()).value, "…aabbcc (14 chars)")
        XCTAssertEqual(row("App version", input()).value, "0.1.0 (7)")
    }

    func testReportFlagsEachFailureStep() {
        XCTAssertEqual(row("Notification permission", input(auth: .denied)).status, .problem)
        XCTAssertEqual(row("APNs token", input(token: nil)).status, .problem)
        XCTAssertEqual(row("Token sync", input(sync: .signedOut(401))).status, .problem)
        XCTAssertEqual(row("Session", input(probe: .signedOut)).status, .problem)
        XCTAssertEqual(row("Session", input(probe: .pageNotReady)).status, .warning)

        func serverRow(_ state: ServerPushState) -> DiagnosticsRow {
            row("Server push status", input(probe: .signedIn(state)))
        }
        func device(env: String = "sandbox", reason: String? = nil, active: Bool = true) -> ServerPushState.Device {
            .init(id: 1, environment: env, tokenSuffix: "aabbcc", disabledReason: reason, isActive: active, lastDeliveredAt: nil)
        }
        XCTAssertEqual(serverRow(.init(apnsConfigured: false, devices: [device()])).value, "APNs is not configured on this server")
        XCTAssertEqual(serverRow(.init(apnsConfigured: true, devices: [])).value, "This device is not registered")
        XCTAssertEqual(serverRow(.init(apnsConfigured: true, devices: [device(reason: "BadDeviceToken", active: false)])).value, "Disabled by server: BadDeviceToken")
        XCTAssertTrue(serverRow(.init(apnsConfigured: true, devices: [device(env: "production")])).value.hasPrefix("Environment mismatch"))
        XCTAssertEqual(serverRow(.init(apnsConfigured: true, devices: [device()])).status, .ok)
    }

    func testRefreshDiagnosticsReprobesAfterFreshRegistration() async {
        let coordinator = PushCoordinator(defaults: UserDefaults(suiteName: "push-refresh-test")!)
        coordinator.service.update(token: "00112233aabbcc")
        let performer = FakePerformer()
        performer.statuses = [200, 201, 200]
        performer.bodies = [
            #"{"apns_configured":true,"mobile_devices":[]}"#,
            "",
            #"{"apns_configured":true,"mobile_devices":[{"id":4,"apns_environment":"sandbox","token_suffix":"aabbcc","disabled_at":null,"disabled_reason":null}]}"#,
        ]
        await coordinator.refreshDiagnostics(server: server, via: performer)
        XCTAssertEqual(performer.requests.map(\.method), ["GET", "POST", "GET"])
        guard case .signedIn(let state) = coordinator.probe else { return XCTFail("expected signed in") }
        XCTAssertEqual(state.device(matching: "00112233aabbcc")?.id, 4)
    }
}
