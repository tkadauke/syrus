import XCTest
@testable import Syrus

final class NavigationPolicyTests: XCTestCase {
    private let policy = NavigationPolicy(server: URL(string: "https://syrus.example.com")!)

    func testSameOriginIsAllowed() {
        XCTAssertEqual(policy.decide(for: URL(string: "https://syrus.example.com/jobs/1")!, isMainFrame: true, isUserLink: true), .allow)
    }

    func testDefaultPortsAreEquivalent() {
        XCTAssertTrue(policy.isSameOrigin(URL(string: "https://syrus.example.com:443/x")!))
        XCTAssertFalse(policy.isSameOrigin(URL(string: "http://syrus.example.com/x")!))
    }

    func testExternalUserLinkOpensExternally() {
        XCTAssertEqual(policy.decide(for: URL(string: "https://github.com/a/b/pull/1")!, isMainFrame: true, isUserLink: true), .openExternally)
    }

    func testExternalSubframeAllowed() {
        XCTAssertEqual(policy.decide(for: URL(string: "https://embed.example.org")!, isMainFrame: false, isUserLink: false), .allow)
    }

    func testCustomSchemesOnlyOnUserTap() {
        let url = URL(string: "mailto:a@b.c")!
        XCTAssertEqual(policy.decide(for: url, isMainFrame: true, isUserLink: true), .openExternally)
        XCTAssertEqual(policy.decide(for: url, isMainFrame: true, isUserLink: false), .cancel)
    }

    func testResolvesTargetPathsSafely() {
        XCTAssertEqual(policy.resolve(targetPath: "/jobs/12")?.absoluteString, "https://syrus.example.com/jobs/12")
        XCTAssertNil(policy.resolve(targetPath: "//evil.example.com"))
        XCTAssertNil(policy.resolve(targetPath: "https://evil.example.com"))
        XCTAssertNil(policy.resolve(targetPath: nil))
    }
}
