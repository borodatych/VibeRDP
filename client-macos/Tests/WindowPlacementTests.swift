import AppKit
import XCTest

@testable import VibeRDP

/// A window opens where the user left it while that place is on a screen, and on the screen with the menu bar
/// once it is not
@MainActor
final class WindowPlacementTests: XCTestCase {
    /// A frame goes to the middle of an area and stays inside it
    func testCenteredFrame() {
        let area = CGRect(x: -1920, y: 100, width: 1920, height: 1100)
        XCTAssertEqual(
            WindowPlacement.centered(CGSize(width: 1000, height: 600), in: area),
            CGRect(x: -1460, y: 350, width: 1000, height: 600))
        XCTAssertEqual(WindowPlacement.centered(CGSize(width: 3000, height: 2000), in: area), area)
    }

    /// The title bar must lie on a screen widely enough to be taken; a frame off every screen is not reachable
    func testReachableTitleBar() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1175), CGRect(x: -3008, y: -800, width: 3008, height: 1980),
        ]
        XCTAssertTrue(WindowPlacement.isReachable(CGRect(x: 100, y: 100, width: 1024, height: 640), on: screens))
        XCTAssertTrue(WindowPlacement.isReachable(CGRect(x: -2000, y: 0, width: 1024, height: 640), on: screens))
        XCTAssertFalse(
            WindowPlacement.isReachable(CGRect(x: 5000, y: 100, width: 1024, height: 640), on: screens),
            "the screen it stood on is gone")
        XCTAssertFalse(
            WindowPlacement.isReachable(CGRect(x: 1880, y: 100, width: 1024, height: 640), on: screens),
            "only a sliver of the title bar is left on the screen")
        XCTAssertFalse(
            WindowPlacement.isReachable(CGRect(x: 100, y: 1170, width: 1024, height: 640), on: screens),
            "the title bar is above the top of the screen")
    }

    /// A kept frame comes back as it was; one whose screen is gone gives way to the middle of the screen with the
    /// menu bar: AppKit does not apply a frame off every screen, so the window keeps the size it was made with
    func testRestoreKeepsTheFrameOrFallsBack() throws {
        let name = "WindowPlacementTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let screen = try XCTUnwrap(WindowPlacement.primaryScreen)
        let kept = WindowPlacement.centered(CGSize(width: 900, height: 600), in: screen.visibleFrame)
            .offsetBy(dx: 20, dy: -20)

        // A shown window, as a kept frame always comes from one: AppKit keeps the frame with the screen it was on
        let first = makeWindow()
        first.setFrame(kept, display: false)
        first.orderFront(nil)
        first.saveFrame(usingName: name)
        first.orderOut(nil)
        let second = makeWindow()
        XCTAssertTrue(WindowPlacement.restore(second, name: name, fallback: screen))
        XCTAssertEqual(second.frame, kept)

        let gone = makeWindow()
        gone.setFrame(CGRect(x: 100_000, y: 100_000, width: 900, height: 600), display: false)
        gone.saveFrame(usingName: name)
        let third = makeWindow()
        XCTAssertFalse(WindowPlacement.restore(third, name: name, fallback: screen))
        XCTAssertEqual(third.frame, WindowPlacement.centered(third.frame.size, in: screen.visibleFrame))
        XCTAssertTrue(WindowPlacement.isReachable(third.frame, on: [screen.visibleFrame]))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
