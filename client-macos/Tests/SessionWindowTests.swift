import AppKit
import XCTest

@testable import VibeRDP

/// The window of a session: it shows the desktop with the keyboard on it, its close button and the menu command
/// end the session, and the desktop follows the window once the window stops changing
@MainActor
final class SessionWindowTests: XCTestCase {
    private var controller: SessionWindowController!
    private var disconnects = 0
    private var sizes: [CGSize] = []

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        disconnects = 0
        sizes = []
        controller = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", frameName: nil,
            onDisconnect: { [weak self] in self?.disconnects += 1 },
            onResize: { [weak self] size in self?.sizes.append(size) })
    }

    override func tearDown() async throws {
        controller?.end()
    }

    /// Before the window shows, the session asks for a desktop the size of its content
    func testDesktopSizeIsTheContentOfTheWindow() throws {
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible, "the window waits for the user to be in")
        XCTAssertEqual(controller.desktopSize, SessionWindowController.defaultSize)
    }

    /// Once shown, the keyboard is on the desktop and Disconnect stands in the title bar, once however often it shows
    func testShowPutsTheKeyboardOnTheDesktop() throws {
        let window = try XCTUnwrap(controller.window)
        controller.show()
        controller.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.firstResponder === controller.desktop)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
    }

    /// The close button ends the session at once, and the window goes
    func testClosingTheWindowDisconnects() throws {
        let window = try XCTUnwrap(controller.window)
        controller.show()
        window.performClose(nil)
        XCTAssertEqual(disconnects, 1)
        XCTAssertFalse(window.isVisible)
    }

    /// The menu command goes up the responder chain from the desktop and reaches the session through this window:
    /// the connections window is not in that chain
    func testDisconnectCommandEndsTheSession() throws {
        let window = try XCTUnwrap(controller.window)
        controller.show()
        let responder = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(responder.tryToPerform(#selector(SessionWindowController.disconnect(_:)), with: nil))
        XCTAssertEqual(disconnects, 1)
    }

    /// A burst of sizes while the corner moves asks the server once, for the last of them
    func testDesktopFollowsTheWindowOnceItStops() async throws {
        let window = try XCTUnwrap(controller.window)
        controller.show()
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await Task.sleep(for: .seconds(SessionWindowController.resizeDelay * 3))
        XCTAssertEqual(sizes, [CGSize(width: 1280, height: 800)])
    }

    /// The overlay covers the desktop while the connection is restored and goes with it
    func testReconnectingOverlayComesAndGoes() {
        controller.show()
        controller.showReconnecting(host: "win")
        XCTAssertTrue(controller.isReconnecting)
        controller.hideReconnecting()
        XCTAssertFalse(controller.isReconnecting)
    }

    /// The end of the session closes the window without asking the session to end again
    func testEndClosesTheWindow() throws {
        let window = try XCTUnwrap(controller.window)
        controller.show()
        controller.end()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(disconnects, 0)
    }
}
