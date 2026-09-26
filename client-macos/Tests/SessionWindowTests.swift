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
    private var scales: [UInt32] = []
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

    /// Sharp off by default: the sizes of these tests are the points of the window on any display
    private func make(
        _ mode: ProfileDisplayMode, fixed: DesktopSize = .standard, sharp: Bool = false, screen: NSScreen? = nil
    ) -> SessionWindowController {
        SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: mode, fixedSize: fixed, sharp: sharp,
            screen: screen, frameName: nil,
            onDisconnect: { [weak self] in self?.disconnects += 1 },
            onResize: { [weak self] desktop in
                self?.sizes.append(desktop.size)
                self?.scales.append(desktop.scale)
            })
    }

    override func tearDown() async throws {
        controller?.end()
    }

    /// Before the window shows, the session asks for a desktop the size of its content
    func testDesktopSizeIsTheContentOfTheWindow() throws {
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible, "the window waits for the user to be in")
        XCTAssertEqual(controller.desktopRequest.size, SessionWindowController.defaultSize)
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
        XCTAssertEqual(controller.desktopRequest.size, CGSize(width: 1280, height: 800))
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
        XCTAssertEqual(
            controller.desktopRequest.size, CGSize(width: content.width.rounded(), height: content.height.rounded()))
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
                fullScreen.desktopRequest.size,
                CGSize(width: expected.width.rounded(), height: expected.height.rounded()))
            XCTAssertTrue(fullScreen.window.map { screen.visibleFrame.contains($0.frame) } ?? false)
            fullScreen.end()
            let fixed = make(.fixed, fixed: DesktopSize(width: 1280, height: 720), screen: screen)
            XCTAssertTrue(fixed.window.map { screen.visibleFrame.contains($0.frame) } ?? false)
            fixed.end()
        }
        controller = make(.window)
    }

    /// Sharp, a window on a Retina display asks for the pixels of its content and the scale of the display;
    /// fixed stays in pixels of Windows at 100 percent
    func testSharpDesktopTakesThePixelsOfItsDisplay() throws {
        controller.end()
        for screen in NSScreen.screens {
            let zoomed = make(.maximized, sharp: true, screen: screen)
            let window = try XCTUnwrap(zoomed.window)
            let content = window.contentRect(forFrameRect: screen.visibleFrame).size
            XCTAssertEqual(
                zoomed.desktopRequest,
                DesktopRequest.points(content, backing: screen.backingScaleFactor, sharp: true))
            XCTAssertEqual(zoomed.desktopRequest.scale, UInt32((screen.backingScaleFactor * 100).rounded()))
            zoomed.end()
            let fixed = make(.fixed, fixed: DesktopSize(width: 1280, height: 720), sharp: true, screen: screen)
            XCTAssertEqual(fixed.desktopRequest, DesktopRequest(size: CGSize(width: 1280, height: 720), scale: 100))
            fixed.end()
        }
        controller = make(.window)
    }

    /// On all monitors every screen gets a window and a view of its part, and the session asks for all of them
    func testAllScreensOpenAWindowOnEach() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("one screen on this Mac") }
        controller.end()
        let all = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: .fullScreen, fixedSize: .standard,
            sharp: true, screen: NSScreen.screens[0], frameName: nil, allScreens: true,
            makeDesktop: { [renderer] in DesktopView(renderer: renderer!) }, onDisconnect: {}, onResize: { _ in })
        let layout = try XCTUnwrap(all.layout)
        XCTAssertEqual(all.desktops.count, NSScreen.screens.count)
        XCTAssertEqual(all.desktopRequest.monitors.count, NSScreen.screens.count)
        XCTAssertEqual(all.desktopRequest.size, layout.bounds.size)
        XCTAssertEqual(all.desktops[0].region, layout.region(of: 0))
        all.end()
        controller = make(.window)
    }

    /// Points become pixels of a Retina display with its scale; without Retina or sharpness they stay points
    func testDesktopRequestOfPoints() {
        let points = CGSize(width: 1503.6, height: 971.2)
        XCTAssertEqual(
            DesktopRequest.points(points, backing: 2, sharp: true),
            DesktopRequest(size: CGSize(width: 3007, height: 1942), scale: 200))
        XCTAssertEqual(
            DesktopRequest.points(points, backing: 2, sharp: false),
            DesktopRequest(size: CGSize(width: 1504, height: 971), scale: 100))
        XCTAssertEqual(
            DesktopRequest.points(points, backing: 1, sharp: true),
            DesktopRequest(size: CGSize(width: 1504, height: 971), scale: 100))
    }


    /// By the window, the next session opens as large as the last window was: the frame is kept under its name
    func testWindowKeepsItsFrame() throws {
        controller.end()
        // Defaults of their own: the frame of the app itself stays as the user left it
        let suite = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: .window, fixedSize: .standard,
            sharp: false, screen: nil, frameName: "Test", frameDefaults: defaults, onDisconnect: {},
            onResize: { _ in })
        first.show()
        first.window?.setContentSize(NSSize(width: 1100, height: 700))
        first.end()
        XCTAssertNotNil(defaults.string(forKey: WindowFrameKeeper.key(for: "Test")), "the frame was not kept")

        let second = SessionWindowController(
            desktop: DesktopView(renderer: renderer), title: "Test", mode: .window, fixedSize: .standard,
            sharp: false, screen: nil, frameName: "Test", frameDefaults: defaults, onDisconnect: {},
            onResize: { _ in })
        XCTAssertEqual(second.desktopRequest.size, CGSize(width: 1100, height: 700))
        second.end()
        controller = make(.window)
    }

    /// Full screen asks for the screen from the start, so the desktop needs no change once the window is there
    func testFullScreenAsksForTheScreen() throws {
        controller.end()
        controller = make(.fullScreen)
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let expected = SessionWindowController.fullScreenSize(of: screen)
        XCTAssertEqual(
            controller.desktopRequest.size, CGSize(width: expected.width.rounded(), height: expected.height.rounded()))
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
