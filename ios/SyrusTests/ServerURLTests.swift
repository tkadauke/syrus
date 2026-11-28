import XCTest
@testable import Syrus

final class ServerURLTests: XCTestCase {
    func testDefaultsToHTTPSAndDropsPathQueryFragment() throws {
        let server = try ServerURL.parse("  Syrus.Example.com/jobs/1?x=1#frag ")
        XCTAssertEqual(server.description, "https://syrus.example.com")
    }

    func testLocalHostsDefaultToHTTPAndKeepPort() throws {
        XCTAssertEqual(try ServerURL.parse("localhost:3000").description, "http://localhost:3000")
        XCTAssertEqual(try ServerURL.parse("127.0.0.1:3000").description, "http://127.0.0.1:3000")
        XCTAssertEqual(try ServerURL.parse("mac-mini.local").description, "http://mac-mini.local")
    }

    func testDropsDefaultPortsAndCredentials() throws {
        XCTAssertEqual(try ServerURL.parse("https://syrus.example.com:443").description, "https://syrus.example.com")
        XCTAssertEqual(try ServerURL.parse("https://user:pw@syrus.example.com").description, "https://syrus.example.com")
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try ServerURL.parse("   ")) { XCTAssertEqual($0 as? ServerURL.ParseError, .empty) }
        XCTAssertThrowsError(try ServerURL.parse("ftp://syrus.example.com")) {
            XCTAssertEqual($0 as? ServerURL.ParseError, .unsupportedScheme("ftp"))
        }
        XCTAssertThrowsError(try ServerURL.parse("https://"))
    }

    func testSameOriginComparesSchemeHostAndEffectivePort() throws {
        let server = try ServerURL.parse("https://syrus.example.com")
        XCTAssertTrue(server.sameOrigin(as: URL(string: "https://SYRUS.example.com:443/jobs")!))
        XCTAssertFalse(server.sameOrigin(as: URL(string: "http://syrus.example.com/")!))
        XCTAssertFalse(server.sameOrigin(as: URL(string: "https://evil.example.com/")!))
        XCTAssertFalse(server.sameOrigin(as: URL(string: "https://syrus.example.com:8443/")!))
    }

    func testResolvingPathRejectsOtherOrigins() throws {
        let server = try ServerURL.parse("https://syrus.example.com")
        XCTAssertEqual(server.resolving(path: "/jobs/12?tab=review")?.absoluteString, "https://syrus.example.com/jobs/12?tab=review")
        XCTAssertNil(server.resolving(path: "//evil.example.com/x"))
        XCTAssertNil(server.resolving(path: "https://evil.example.com"))
        XCTAssertNil(server.resolving(path: "/\\evil.example.com"))
        XCTAssertNil(server.resolving(path: "jobs/12"))
    }
}
