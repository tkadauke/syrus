import XCTest
@testable import Syrus

final class ReleaseMetadataTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: AppDelegate.self) }

    func testPrivacyManifestIsBundledAndDeclaresNoTracking() throws {
        let url = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url))
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }

    func testExportComplianceDeclared() {
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }

    func testBundleIdentifierDefaultsFromConfig() {
        XCTAssertEqual(bundle.bundleIdentifier, "app.syrus.ios")
    }
}
