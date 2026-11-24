import XCTest
@testable import SyrusHaptics

final class HapticRequestParserTests: XCTestCase {
    func testAcceptsSelection() {
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "selection"]), .success(.selection))
    }

    func testAcceptsEveryImpactStyle() {
        for style in HapticRequest.ImpactStyle.allCases {
            XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "impact", "style": style.rawValue]), .success(.impact(style)))
        }
    }

    func testRejectsMalformedBodies() {
        XCTAssertEqual(HapticRequestParser.parse("selection"), .failure(.notAnObject))
        XCTAssertEqual(HapticRequestParser.parse(["kind": "selection"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HapticRequestParser.parse(["v": 2, "kind": "selection"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HapticRequestParser.parse(["v": true, "kind": "selection"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1.5, "kind": "selection"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "notification"]), .failure(.unknownKind))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": 3]), .failure(.unknownKind))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "impact"]), .failure(.invalidStyle))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "impact", "style": "huge"]), .failure(.invalidStyle))
    }

    func testRejectsUnknownKeys() {
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "selection", "style": "light"]), .failure(.unknownKey("style")))
        XCTAssertEqual(HapticRequestParser.parse(["v": 1, "kind": "impact", "style": "light", "count": 9]), .failure(.unknownKey("count")))
    }
}
