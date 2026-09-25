import XCTest

@testable import VibeRDP

final class LocalizationTests: XCTestCase {
    /// Filled against the base text: the language of the launch depends on the Mac that runs the tests
    func testNamedPlaceholderIsFilled() {
        XCTAssertEqual(Localization.fill(TextKey.menuAppQuit.baseText, ["app": "VibeRDP"]), "Завершить VibeRDP")
    }

    func testPlaceholderWithoutValueStaysVisible() {
        XCTAssertEqual(Localization.fill(TextKey.menuAppQuit.baseText, [:]), "Завершить {app}")
        XCTAssertFalse(Localization.text(.menuAppQuit).isEmpty)
    }

    func testEveryKeyHasBaseTextAndDottedName() {
        for key in TextKey.allCases {
            XCTAssertFalse(key.baseText.isEmpty, "\(key.rawValue) has no base text")
            XCTAssertTrue(key.rawValue.contains("."), "\(key.rawValue) is not a flat dotted key")
        }
    }
}
