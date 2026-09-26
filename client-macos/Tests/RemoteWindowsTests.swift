import XCTest

@testable import VibeRDP

/// The windows of the host as the messages of the helper build them, section 6 of protocol/seam-protocol.md
final class RemoteWindowsTests: XCTestCase {
    private func rect(_ x: Int64, _ y: Int64, _ width: Int64, _ height: Int64) -> MessagePackValue {
        .array([.int(x), .int(y), .int(width), .int(height)])
    }

    private func message(_ type: String, _ entries: [(String, MessagePackValue)]) -> MessagePackValue {
        .map([("type", .string(type))] + entries)
    }

    /// The example of the specification
    private var excel: MessagePackValue {
        message(
            "window.create",
            [
                ("id", .uint(132_290)), ("rect", rect(120, 80, 1280, 800)), ("title", .string("Книга1 - Excel")),
                ("exe", .string("EXCEL.EXE")), ("pid", .uint(7412)),
            ])
    }

    func testCreateTakesEveryKeyAndDefaults() {
        var windows = RemoteWindows()
        XCTAssertEqual(windows.apply(excel).change, .created(132_290))
        let window = windows.windows[132_290]
        XCTAssertEqual(window?.frame, CGRect(x: 120, y: 80, width: 1280, height: 800))
        XCTAssertEqual(window?.title, "Книга1 - Excel")
        XCTAssertEqual(window?.exe, "EXCEL.EXE")
        XCTAssertEqual(window?.pid, 7412)
        XCTAssertEqual(window?.state, .normal)
        XCTAssertEqual(window?.kind, .app)
        XCTAssertEqual(windows.order, [132_290])
    }

    func testUpdateChangesOnlyItsKeys() {
        var windows = RemoteWindows()
        _ = windows.apply(excel)
        let update = message(
            "window.update", [("id", .uint(132_290)), ("rect", rect(-6016, 0, 800, 600)), ("state", .string("maximized"))])
        XCTAssertEqual(windows.apply(update).change, .updated(132_290))
        XCTAssertEqual(windows.windows[132_290]?.frame, CGRect(x: -6016, y: 0, width: 800, height: 600))
        XCTAssertEqual(windows.windows[132_290]?.state, .maximized)
        XCTAssertEqual(windows.windows[132_290]?.title, "Книга1 - Excel")
    }

    func testOrderFocusAndDestroy() {
        var windows = RemoteWindows()
        _ = windows.apply(excel)
        _ = windows.apply(message("window.create", [("id", .uint(5)), ("rect", rect(0, 0, 10, 10))]))
        _ = windows.apply(message("zorder", [("ids", .array([.uint(132_290), .uint(99), .uint(5)]))]))
        XCTAssertEqual(windows.order, [132_290, 5])
        _ = windows.apply(message("foreground", [("id", .uint(5))]))
        XCTAssertEqual(windows.foreground, 5)
        XCTAssertEqual(windows.apply(message("window.destroy", [("id", .uint(5))])).change, .destroyed(5))
        XCTAssertEqual(windows.order, [132_290])
        XCTAssertEqual(windows.foreground, 0)
        _ = windows.apply(message("foreground", [("id", .uint(99))]))
        XCTAssertEqual(windows.foreground, 0, "a window outside the list is no focus")
    }

    func testIconSurvivesAFreshCreate() {
        var windows = RemoteWindows()
        _ = windows.apply(excel)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        XCTAssertEqual(windows.apply(message("window.icon", [("id", .uint(132_290)), ("png", .binary(png))])).change,
                       .icon(132_290))
        _ = windows.apply(excel)
        XCTAssertEqual(windows.windows[132_290]?.icon, png)
        XCTAssertEqual(windows.order, [132_290])
    }

    func testMalformedMessagesAreSkipped() {
        var windows = RemoteWindows()
        let skipped: [MessagePackValue] = [
            message("window.create", [("id", .uint(1))]),
            message("window.create", [("id", .uint(1)), ("rect", rect(0, 0, -1, 5))]),
            message("window.update", [("id", .uint(7))]),
            message("window.destroy", [("id", .uint(7))]),
            message("window.icon", [("id", .uint(7)), ("png", .binary(Data()))]),
            message("window.snap", []),
        ]
        for body in skipped {
            let outcome = windows.apply(body)
            XCTAssertNil(outcome.change, "\(body)")
            XCTAssertNotNil(outcome.note, "\(body)")
        }
        XCTAssertTrue(windows.windows.isEmpty)
    }
}
