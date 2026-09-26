import AppKit
import XCTest

@testable import VibeRDP

/// The window of a session: it shows the desktop with the keyboard on it, its close button and the menu command
/// end the session, and the desktop follows the window once the window stops changing
/// The display mode of the connection sets the desktop it asks for and whether the window changes it
@MainActor
final class SessionWindowTests: XCTestCase {
    private var controller: SessionWindowController!
    private var disconnects = 0
    private var sizes: [CGSize] = []
    private var renderer: FrameRenderer!

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        self.renderer = renderer
        disconnects = 0
        sizes = []
        controller = make(.window)
    }

    private func make(_ mode: ProfileDisplayMode, fixed: DesktopSize = .standard) -> SessionWindowController {
        SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: mode, fixedSize: fixed, frameName: nil,
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

    /// A fixed desktop asks for its own size, opens a window as large as the screen lets, and a change of the window
    /// sends nothing: the frame scales into it
    func testFixedDesktopKeepsItsSize() async throws {
        controller.end()
        let size = DesktopSize(width: 1280, height: 800)
        controller = make(.fixed, fixed: size)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.desktopSize, CGSize(width: 1280, height: 800))
        let visible = (window.screen ?? NSScreen.main).map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        XCTAssertEqual(window.contentLayoutRect.size, SessionWindowController.contentSize(for: size, within: visible))
        controller.show()
        window.setContentSize(NSSize(width: 900, height: 600))
        try await Task.sleep(for: .seconds(SessionWindowController.resizeDelay * 3))
        XCTAssertEqual(sizes, [], "a fixed desktop does not follow the window")
    }

    /// Full screen asks for the screen from the start, so the desktop needs no change once the window is there
    func testFullScreenAsksForTheScreen() throws {
        controller.end()
        controller = make(.fullScreen)
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let expected = SessionWindowController.fullScreenSize(of: screen)
        XCTAssertEqual(
            controller.desktopSize, CGSize(width: expected.width.rounded(), height: expected.height.rounded()))
    }

    /// The desktop of each mode, and the window of a fixed desktop on a smaller screen
    func testDesktopAndWindowSizes() {
        let content = CGSize(width: 1023.6, height: 640.2)
        let screen = CGSize(width: 3008, height: 1942)
        let fixed = DesktopSize(width: 1920, height: 1080)
        XCTAssertEqual(
            SessionWindowController.desktopSize(mode: .window, fixed: fixed, content: content, fullScreen: screen),
            CGSize(width: 1024, height: 640))
        XCTAssertEqual(
            SessionWindowController.desktopSize(mode: .fullScreen, fixed: fixed, content: content, fullScreen: screen),
            screen)
        XCTAssertEqual(
            SessionWindowController.desktopSize(mode: .fixed, fixed: fixed, content: content, fullScreen: screen),
            CGSize(width: 1920, height: 1080))
        XCTAssertEqual(
            SessionWindowController.contentSize(for: fixed, within: CGSize(width: 1280, height: 800)),
            CGSize(width: 1280, height: 720), "the proportions stay, the window fits the screen")
        XCTAssertEqual(
            SessionWindowController.contentSize(for: fixed, within: CGSize(width: 3008, height: 1900)),
            CGSize(width: 1920, height: 1080), "a screen large enough shows the desktop as it is")
        XCTAssertEqual(SessionWindowController.contentSize(for: fixed, within: nil), CGSize(width: 1920, height: 1080))
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
