import AppKit
import XCTest

@testable import VibeRDP

/// The tests run inside the launched app: its window and menu bar are the real ones
@MainActor
final class MainWindowTests: XCTestCase {
    func testMainWindowIsShown() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let window = try XCTUnwrap(delegate.mainWindow)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, AppDelegate.appName)
        XCTAssertEqual(AppDelegate.appName, "VibeRDP")
    }

    func testMenuBarHasApplicationFileAndWindowMenus() throws {
        let bar = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(bar.items.count, 3)
        XCTAssertIdentical(NSApp.windowsMenu, bar.items[2].submenu)

        let application = try XCTUnwrap(bar.items[0].submenu)
        let quit = try XCTUnwrap(application.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.title, Localization.text(.menuAppQuit, ["app": "VibeRDP"]))

        let file = try XCTUnwrap(bar.items[1].submenu)
        let disconnect = try XCTUnwrap(
            file.items.first { $0.action == #selector(ConnectionViewController.disconnect(_:)) })
        XCTAssertEqual(disconnect.title, Localization.text(.menuFileDisconnect))
        XCTAssertEqual(disconnect.keyEquivalent, "")

        // The shortcut is the system's own, so only the item is checked
        XCTAssertNotNil(bar.items[2].submenu?.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        let window = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.mainWindow)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
    }
}
