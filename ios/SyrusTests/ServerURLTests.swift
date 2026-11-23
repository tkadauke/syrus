import XCTest
@testable import Syrus

final class ServerURLTests: XCTestCase {
    private func parse(_ input: String) throws -> ServerURL { try ServerURL.parse(input).get() }

    func testBareHostDefaultsToHTTPS() throws {
        XCTAssertEqual(try parse("syrus.example.com").absoluteString, "https://syrus.example.com")
    }

    func testPrivateHostsDefaultToHTTP() throws {
        XCTAssertEqual(try parse("localhost:3000").absoluteString, "http://localhost:3000")
        XCTAssertEqual(try parse("192.168.1.20:3000").absoluteString, "http://192.168.1.20:3000")
        XCTAssertEqual(try parse("172.20.0.5").absoluteString, "http://172.20.0.5")
        XCTAssertEqual(try parse("mac.local").absoluteString, "http://mac.local")
        XCTAssertEqual(try parse("172.32.0.5").absoluteString, "https://172.32.0.5")
    }

    func testNormalizesCaseTrailingSlashQueryAndCredentials() throws {
        let server = try parse("  HTTPS://user:pw@Syrus.Example.com/prefix/?a=1#frag ")
        XCTAssertEqual(server.absoluteString, "https://syrus.example.com/prefix")
        XCTAssertFalse(server.isInsecure)
        XCTAssertTrue(try parse("http://localhost:3000").isInsecure)
    }

    func testRejectsBadInput() {
        XCTAssertEqual(ServerURL.parse("   "), .failure(.empty))
        XCTAssertEqual(ServerURL.parse("ftp://example.com"), .failure(.unsupportedScheme("ftp")))
        XCTAssertEqual(ServerURL.parse("https://"), .failure(.invalid))
    }

    func testResolvingPathsKeepsPrefixAndRejectsForeignPaths() throws {
        let server = try parse("https://example.com/syrus")
        XCTAssertEqual(server.resolving(path: "/jobs/42")?.absoluteString, "https://example.com/syrus/jobs/42")
        XCTAssertEqual(server.resolving(path: "/jobs?tab=a")?.absoluteString, "https://example.com/syrus/jobs?tab=a")
        XCTAssertNil(server.resolving(path: "//evil.example"))
        XCTAssertNil(server.resolving(path: "jobs"))
    }

    func testSameOriginComparesSchemeHostAndEffectivePort() throws {
        let server = try parse("https://example.com")
        XCTAssertTrue(server.isSameOrigin(as: URL(string: "https://EXAMPLE.com:443/a")!))
        XCTAssertFalse(server.isSameOrigin(as: URL(string: "http://example.com/a")!))
        XCTAssertFalse(server.isSameOrigin(as: URL(string: "https://example.com:8443/a")!))
        XCTAssertFalse(server.isSameOrigin(as: URL(string: "https://other.example.com/a")!))
    }
}
