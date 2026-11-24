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

    /// Reads the committed default from the xcconfig source rather than the
    /// running bundle, so a local PRODUCT_BUNDLE_IDENTIFIER override in the
    /// git-ignored Local.xcconfig does not break simulator tests.
    func testBundleIdentifierDefaultsFromConfig() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let shared = tests.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Shared.xcconfig")
        let text = try String(contentsOf: shared, encoding: .utf8)
        XCTAssertTrue(text.contains("PRODUCT_BUNDLE_IDENTIFIER = app.syrus.ios"))
        XCTAssertNotNil(bundle.bundleIdentifier)
    }
}
