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

    /// A kept frame comes back exactly, on its screen; one whose screen is gone gives way to the middle of the
    /// fallback screen; a frame AppKit kept before comes back too, so the place is not lost
    func testKeeperRestoresTheFrameOrFallsBack() throws {
        let suite = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = try XCTUnwrap(WindowPlacement.primaryScreen)
        let kept = WindowPlacement.centered(CGSize(width: 900, height: 600), in: screen.visibleFrame)
            .offsetBy(dx: 20, dy: -20)

        let first = makeWindow()
        let keeper = WindowFrameKeeper(window: first, name: "Test", defaults: defaults, fallback: screen)
        XCTAssertFalse(keeper.restored, "nothing was kept yet")
        first.setFrame(kept, display: false)
        keeper.save()
        keeper.stop()
        let second = makeWindow()
        XCTAssertTrue(WindowFrameKeeper(window: second, name: "Test", defaults: defaults, fallback: screen).restored)
        XCTAssertEqual(second.frame, kept)

        // Every screen that is there now takes its kept frame back, the second monitor as the first
        for other in NSScreen.screens {
            let place = WindowPlacement.centered(CGSize(width: 800, height: 500), in: other.visibleFrame)
            defaults.set(NSStringFromRect(place), forKey: WindowFrameKeeper.key(for: "Test"))
            let window = makeWindow()
            let keeper = WindowFrameKeeper(window: window, name: "Test", defaults: defaults, fallback: screen)
            XCTAssertTrue(keeper.restored)
            keeper.stop()
            XCTAssertEqual(window.frame, place, "\(other.localizedName)")
        }

        defaults.set(
            NSStringFromRect(CGRect(x: 100_000, y: 100_000, width: 900, height: 600)),
            forKey: WindowFrameKeeper.key(for: "Test"))
        let third = makeWindow()
        XCTAssertFalse(WindowFrameKeeper(window: third, name: "Test", defaults: defaults, fallback: screen).restored)
        XCTAssertEqual(third.frame, WindowPlacement.centered(third.frame.size, in: screen.visibleFrame))

        defaults.removeObject(forKey: WindowFrameKeeper.key(for: "Test"))
        defaults.set(
            "\(Int(kept.minX)) \(Int(kept.minY)) \(Int(kept.width)) \(Int(kept.height)) 0 0 1 1 ",
            forKey: WindowFrameKeeper.legacyKey(for: "Test"))
        let fourth = makeWindow()
        XCTAssertTrue(WindowFrameKeeper(window: fourth, name: "Test", defaults: defaults, fallback: screen).restored)
        XCTAssertEqual(fourth.frame, kept.integral)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
