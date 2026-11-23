import XCTest
@testable import Syrus

final class NavigationPolicyTests: XCTestCase {
    private let policy = NavigationPolicy(server: try! ServerURL.parse("https://syrus.example.com").get())

    func testSameOriginLoadsInApp() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://syrus.example.com/jobs/1"), isMainFrame: true), .allow)
    }

    func testCrossOriginTopLevelLeavesTheApp() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://github.com/acme/widgets/pull/1"), isMainFrame: true), .openExternally)
        XCTAssertEqual(policy.decision(for: URL(string: "http://syrus.example.com/"), isMainFrame: true), .openExternally)
    }

    func testCrossOriginSubframesAreAllowed() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://www.youtube.com/embed/x"), isMainFrame: false), .allow)
    }

    func testMailAndTelAreExternalAndOtherSchemesCancelled() {
        XCTAssertEqual(policy.decision(for: URL(string: "mailto:a@b.c"), isMainFrame: true), .openExternally)
        XCTAssertEqual(policy.decision(for: URL(string: "tel:123"), isMainFrame: true), .openExternally)
        XCTAssertEqual(policy.decision(for: URL(string: "javascript:alert(1)"), isMainFrame: true), .cancel)
        XCTAssertEqual(policy.decision(for: URL(string: "file:///etc/passwd"), isMainFrame: true), .cancel)
        XCTAssertEqual(policy.decision(for: nil, isMainFrame: true), .cancel)
    }

    func testAboutBlobAndDataAreAllowed() {
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank"), isMainFrame: true), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "blob:https://syrus.example.com/abc"), isMainFrame: false), .allow)
    }
}
