import AppKit
import XCTest

@testable import VibeRDP

/// Messages of the helper become windows of the Mac, placed where the geometry says, and go away with them
@MainActor
final class SeamWindowsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var seam: SeamWindows!
    private var remote = RemoteWindows()
    private var moves: [(UInt64, CGRect)] = []
    private var activated: [UInt64] = []

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else { throw XCTSkip("no Metal device") }
        let layout = MonitorLayout(screens: [(frame: screen, backing: 1)], primary: 0, sharp: false)
        seam = SeamWindows(
            geometry: SeamGeometry(layout: layout, screens: [screen]),
            makeDesktop: { DesktopView(renderer: renderer) }, onDisconnect: {},
            onMove: { [weak self] id, rect in self?.moves.append((id, rect)) },
            onActivate: { [weak self] id in self?.activated.append(id) })
        remote = RemoteWindows()
        moves = []
        activated = []
    }

    override func tearDown() async throws {
        seam?.deactivate()
        seam = nil
    }

    private func send(_ message: MessagePackValue) {
        if let change = remote.apply(message).change {
            seam.apply(change, remote)
        }
    }

    private func create(_ id: UInt64, _ x: Int64, _ y: Int64, state: String = "normal") -> MessagePackValue {
        .map([
            ("type", .string("window.create")), ("id", .uint(id)),
            ("rect", .array([.int(x), .int(y), .int(400), .int(300)])), ("state", .string(state)),
            ("title", .string("Книга1 - Excel")),
        ])
    }

    func testWindowsShowOnlyWhileActive() {
        send(create(1, 100, 50))
        XCTAssertNil(seam.window(for: 1), "before the link is ready the desktop shows")
        seam.activate(remote)
        let window = seam.window(for: 1)
        XCTAssertEqual(window?.frame, CGRect(x: 100, y: 900 - 50 - 300, width: 400, height: 300))
        XCTAssertEqual(window?.title, "Книга1 - Excel")
        XCTAssertEqual(window?.isVisible, true)
        seam.deactivate()
        XCTAssertNil(seam.window(for: 1))
    }

    func testWindowsFollowTheHost() {
        seam.activate(remote)
        send(create(1, 100, 50))
        send(.map([("type", .string("window.update")), ("id", .uint(1)), ("rect", .array([.int(0), .int(0), .int(400), .int(300)]))]))
        XCTAssertEqual(seam.window(for: 1)?.frame.origin, CGPoint(x: 0, y: 600))
        send(.map([("type", .string("window.update")), ("id", .uint(1)), ("state", .string("minimized"))]))
        XCTAssertNil(seam.window(for: 1), "a minimized window is not shown")
        send(.map([("type", .string("window.update")), ("id", .uint(1)), ("state", .string("normal"))]))
        XCTAssertNotNil(seam.window(for: 1))
        send(.map([("type", .string("window.destroy")), ("id", .uint(1))]))
        XCTAssertNil(seam.window(for: 1))
    }

    func testOrderOfTheHostStacksTheWindows() {
        seam.activate(remote)
        send(create(1, 0, 0))
        send(create(2, 50, 50))
        send(.map([("type", .string("zorder")), ("ids", .array([.uint(1), .uint(2)]))]))
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        guard let first = seam.window(for: 1)?.windowNumber, let second = seam.window(for: 2)?.windowNumber,
            let top = numbers.firstIndex(of: NSNumber(value: first)),
            let below = numbers.firstIndex(of: NSNumber(value: second))
        else { return XCTFail("both windows are on screen") }
        XCTAssertLessThan(top, below, "window 1 is above window 2, as the host has them")
    }

    /// The host moving a window is not sent back; the Mac moving it is
    func testOnlyMovesOfTheMacGoToTheHost() {
        seam.activate(remote)
        send(create(1, 100, 50))
        send(.map([("type", .string("window.update")), ("id", .uint(1)), ("rect", .array([.int(0), .int(0), .int(400), .int(300)]))]))
        XCTAssertTrue(moves.isEmpty, "the moves of the host stay on the Mac")
        seam.window(for: 1)?.setFrame(CGRect(x: 720, y: 0, width: 720, height: 900), display: false)
        XCTAssertEqual(moves.last?.0, 1)
        XCTAssertEqual(moves.last?.1, CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    /// A window made key on the Mac goes forward on the host; the one the host has in front already does not
    /// The app under test is not active, so AppKit makes no window key: the notification comes as AppKit sends it
    func testKeyWindowOfTheMacActivatesTheHost() {
        seam.activate(remote)
        send(create(1, 0, 0))
        send(create(2, 50, 50))
        send(.map([("type", .string("foreground")), ("id", .uint(2))]))
        becameKey(1)
        XCTAssertEqual(activated, [1])
        send(.map([("type", .string("foreground")), ("id", .uint(1))]))
        becameKey(2)
        becameKey(1)
        XCTAssertEqual(activated, [1, 2], "the window the host has in front is not asked for again")
    }

    private func becameKey(_ id: UInt64) {
        seam.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: seam.window(for: id)))
    }
}
