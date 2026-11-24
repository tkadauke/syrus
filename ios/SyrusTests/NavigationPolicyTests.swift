import XCTest
@testable import Syrus

final class NavigationPolicyTests: XCTestCase {
    private let server = try! ServerURL.parse("https://syrus.example.com")

    private func decide(_ url: String, mainFrame: Bool = true, link: Bool = false) -> NavigationPolicy.Decision {
        NavigationPolicy.decide(url: URL(string: url), server: server, isMainFrame: mainFrame, isLinkActivation: link)
    }

    func testSameOriginStaysInApp() {
        XCTAssertEqual(decide("https://syrus.example.com/jobs/1", link: true), .allow)
    }

    func testCrossOriginLinkTapOpensExternally() {
        XCTAssertEqual(decide("https://github.com/o/r/pull/1", link: true), .openExternally)
    }

    func testCrossOriginRedirectAndSubframesStayInApp() {
        XCTAssertEqual(decide("https://github.com/login/oauth/authorize"), .allow)
        XCTAssertEqual(decide("https://embed.example.org/frame", mainFrame: false, link: true), .allow)
    }

    func testNonWebSchemesGoToTheSystemAndMissingURLsCancel() {
        XCTAssertEqual(decide("mailto:ops@example.com"), .openExternally)
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertEqual(NavigationPolicy.decide(url: nil, server: server, isMainFrame: true, isLinkActivation: false), .cancel)
    }
}
