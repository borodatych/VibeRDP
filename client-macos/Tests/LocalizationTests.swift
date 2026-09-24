import XCTest

@testable import VibeRDP

final class LocalizationTests: XCTestCase {
    func testNamedPlaceholderIsFilled() {
        XCTAssertEqual(Localization.text(.menuAppQuit, ["app": "VibeRDP"]), "Завершить VibeRDP")
    }

    func testPlaceholderWithoutValueStaysVisible() {
        XCTAssertEqual(Localization.text(.menuAppQuit), "Завершить {app}")
    }

    func testEveryKeyHasBaseTextAndDottedName() {
        for key in TextKey.allCases {
            XCTAssertFalse(key.baseText.isEmpty, "\(key.rawValue) has no base text")
            XCTAssertTrue(key.rawValue.contains("."), "\(key.rawValue) is not a flat dotted key")
        }
    }
}
