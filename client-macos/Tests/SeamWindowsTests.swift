import AppKit
import XCTest

@testable import VibeRDP

/// Messages of the helper become windows of the Mac, placed where the geometry says, and go away with them
@MainActor
final class SeamWindowsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var seam: SeamWindows!
    private var remote = RemoteWindows()

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else { throw XCTSkip("no Metal device") }
        let layout = MonitorLayout(screens: [(frame: screen, backing: 1)], primary: 0, sharp: false)
        seam = SeamWindows(
            geometry: SeamGeometry(layout: layout, screens: [screen]),
            makeDesktop: { DesktopView(renderer: renderer) }, onDisconnect: {})
        remote = RemoteWindows()
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
}
