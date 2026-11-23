import XCTest
@testable import Syrus

final class ServerURLTests: XCTestCase {
    func testDefaultsToHTTPSForPublicHosts() throws {
        XCTAssertEqual(try ServerURL.parse("Syrus.Example.com").absoluteString, "https://syrus.example.com")
    }

    func testDefaultsToHTTPForLocalHosts() throws {
        XCTAssertEqual(try ServerURL.parse("localhost:3000").absoluteString, "http://localhost:3000")
        XCTAssertEqual(try ServerURL.parse("192.168.1.20:3000").scheme, "http")
        XCTAssertEqual(try ServerURL.parse("mac.local").scheme, "http")
    }

    func testStripsTrailingSlashQueryAndFragment() throws {
        XCTAssertEqual(try ServerURL.parse("https://syrus.example.com/?a=1#x").absoluteString, "https://syrus.example.com")
    }

    func testKeepsPathPrefix() throws {
        XCTAssertEqual(try ServerURL.parse("https://example.com/syrus").absoluteString, "https://example.com/syrus")
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try ServerURL.parse("   ")) { XCTAssertEqual($0 as? ServerURL.ParseError, .empty) }
        XCTAssertThrowsError(try ServerURL.parse("ftp://example.com")) { XCTAssertEqual($0 as? ServerURL.ParseError, .unsupportedScheme) }
    }
}
