import XCTest

@testable import VibeRDP

/// The layout of Windows follows the Mac: the language named, and the request the helper takes
final class InputLanguageTests: XCTestCase {
    func testFirstLanguageOfTheSourceIsTheOne() {
        XCTAssertEqual(InputLanguage.first(of: ["ru", "en"]), "ru")
        XCTAssertEqual(InputLanguage.first(of: ["", "en"]), "en")
        XCTAssertNil(InputLanguage.first(of: []))
    }

    func testRequestNamesTheLanguage() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        XCTAssertNil(link.layout("ru"))
        _ = link.opened(at: Date())
        _ = link.received(
            MessagePack.encode(.map([
                ("type", .string("hello")), ("version", .uint(1)),
                ("capabilities", .array([.string("keyboard-layout")])),
            ])), at: Date())
        XCTAssertEqual(
            link.layout("ru"),
            .map([("type", .string("input.layout")), ("seq", .uint(1)), ("language", .string("ru"))]))
    }

    /// Whatever the Mac types with now, it names a language
    func testCurrentSourceNamesALanguage() {
        XCTAssertNotNil(InputLanguage.current())
    }
}
