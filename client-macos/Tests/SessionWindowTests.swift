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

    private func make(
        _ mode: ProfileDisplayMode, fixed: DesktopSize = .standard, screen: NSScreen? = nil
    ) -> SessionWindowController {
        SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: mode, fixedSize: fixed, screen: screen,
            frameName: nil,
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

    /// A zoomed window covers the free space of its screen, as a double click on its title makes it,
    /// and asks for a desktop of its content; a change of it after that goes to the server, as by the window
    func testZoomedWindowCoversTheScreen() async throws {
        controller.end()
        controller = make(.maximized)
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        XCTAssertEqual(window.frame, screen.visibleFrame)
        let content = window.contentRect(forFrameRect: screen.visibleFrame).size
        XCTAssertEqual(controller.desktopSize, CGSize(width: content.width.rounded(), height: content.height.rounded()))
        controller.show()
        window.setContentSize(NSSize(width: 1100, height: 700))
        try await Task.sleep(for: .seconds(SessionWindowController.resizeDelay * 3))
        XCTAssertEqual(sizes, [CGSize(width: 1100, height: 700)])
    }

    /// Every mode but the window one opens on the screen it is given, the screen of the connections
    func testSessionOpensOnTheScreenOfTheConnections() throws {
        controller.end()
        for screen in NSScreen.screens {
            let zoomed = make(.maximized, screen: screen)
            XCTAssertEqual(zoomed.window?.frame, screen.visibleFrame)
            zoomed.end()
            let fullScreen = make(.fullScreen, screen: screen)
            let expected = SessionWindowController.fullScreenSize(of: screen)
            XCTAssertEqual(
                fullScreen.desktopSize, CGSize(width: expected.width.rounded(), height: expected.height.rounded()))
            XCTAssertTrue(fullScreen.window.map { screen.visibleFrame.contains($0.frame) } ?? false)
            fullScreen.end()
            let fixed = make(.fixed, fixed: DesktopSize(width: 1280, height: 720), screen: screen)
            XCTAssertTrue(fixed.window.map { screen.visibleFrame.contains($0.frame) } ?? false)
            fixed.end()
        }
        controller = make(.window)
    }

    /// A frame goes to the middle of an area and stays inside it
    func testCenteredFrame() {
        let area = CGRect(x: -1920, y: 100, width: 1920, height: 1100)
        XCTAssertEqual(
            SessionWindowController.centered(CGSize(width: 1000, height: 600), in: area),
            CGRect(x: -1460, y: 350, width: 1000, height: 600))
        XCTAssertEqual(SessionWindowController.centered(CGSize(width: 3000, height: 2000), in: area), area)
    }

    /// By the window, the next session opens as large as the last window was: the frame is kept under its name
    func testWindowKeepsItsFrame() throws {
        controller.end()
        let name = "SessionWindowTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let first = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: .window, fixedSize: .standard,
            screen: nil, frameName: name, onDisconnect: {}, onResize: { _ in })
        first.show()
        first.window?.setContentSize(NSSize(width: 1100, height: 700))
        first.end()
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)"), "the frame was not kept")

        controller = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: .window, fixedSize: .standard,
            screen: nil, frameName: name, onDisconnect: {}, onResize: { _ in })
        XCTAssertEqual(controller.desktopSize, CGSize(width: 1100, height: 700))
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
            SessionWindowController.desktopSize(mode: .maximized, fixed: fixed, content: content, fullScreen: screen),
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
