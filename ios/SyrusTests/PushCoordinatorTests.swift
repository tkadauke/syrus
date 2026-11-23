import XCTest
@testable import Syrus

@MainActor
final class PushCoordinatorTests: XCTestCase {
    final class FakeRunner: WebScriptRunner {
        var calls: [(script: String, arguments: [String: Any])] = []
        var status: Int? = 200
        func runScript(_ script: String, arguments: [String: Any]) async -> Int? {
            calls.append((script, arguments))
            return status
        }
    }

    private let server = try! ServerURL.parse("https://syrus.example.com").get()

    func testRegistersOnlyOnceATokenIsKnownAndThrottlesRepeats() async {
        let push = PushCoordinator()
        let runner = FakeRunner()
        let start = Date()

        await push.registerIfPossible(using: runner, server: server, now: start)
        XCTAssertTrue(runner.calls.isEmpty, "no token yet")

        push.didRegister(deviceToken: Data([0xDE, 0xAD]))
        await push.registerIfPossible(using: runner, server: server, now: start)
        await push.registerIfPossible(using: runner, server: server, now: start.addingTimeInterval(1))
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual((runner.calls[0].arguments["body"] as? [String: String])?["token"], "dead")
        XCTAssertEqual(push.lastOutcome, .registered)

        await push.registerIfPossible(using: runner, server: server, now: start.addingTimeInterval(10))
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testSignedOutOutcomeIsRecordedAndNotTreatedAsRegistered() async {
        let push = PushCoordinator()
        let runner = FakeRunner()
        runner.status = 401
        push.didRegister(deviceToken: Data([0x01]))

        await push.registerIfPossible(using: runner, server: server)
        XCTAssertEqual(push.lastOutcome, .signedOut)

        await push.unregister(using: runner, server: server)
        XCTAssertEqual(runner.calls.count, 1, "nothing to unregister when never registered")
    }

    func testUnregisterRemovesTheTokenFromTheRegisteredServer() async {
        let push = PushCoordinator()
        let runner = FakeRunner()
        push.didRegister(deviceToken: Data([0x01]))
        await push.registerIfPossible(using: runner, server: server)
        await push.unregister(using: runner, server: server)

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[1].script.contains("'DELETE'"))
    }

    func testTapRoutesOnlyValidPaths() {
        let push = PushCoordinator()
        push.handleTap(userInfo: ["syrus": ["path": "https://evil.example"]])
        XCTAssertNil(push.pendingPath)
        push.handleTap(userInfo: ["syrus": ["path": "/jobs/9"]])
        XCTAssertEqual(push.pendingPath, "/jobs/9")
    }
}
