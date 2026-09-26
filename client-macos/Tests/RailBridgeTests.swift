import XCTest

@testable import VibeRDP

/// RemoteApp window orders in the words of the Seam protocol: the model of the windows takes them as it takes
/// the messages of the helper
final class RailBridgeTests: XCTestCase {
    private func created(_ id: UInt64) -> RailBridge.Order {
        var order = RailBridge.Order(id: id, created: true)
        order.showState = 5
        order.title = "Notepad"
        order.offset = CGPoint(x: -8, y: 40)
        order.size = CGSize(width: 216, height: 158)
        order.visibleOffset = CGPoint(x: -8, y: 40)
        order.region = CGRect(x: 8, y: 0, width: 200, height: 150)
        return order
    }

    func testOrdersBecomeWindowsOfTheModel() {
        var bridge = RailBridge()
        var model = RemoteWindows()
        bridge.window(created(7)).forEach { _ = model.apply($0) }
        XCTAssertEqual(model.windows[7]?.frame, CGRect(x: 0, y: 40, width: 200, height: 150), "the visible part only")
        XCTAssertEqual(model.windows[7]?.title, "Notepad")
        var moved = RailBridge.Order(id: 7)
        moved.offset = CGPoint(x: 92, y: 140)
        moved.visibleOffset = CGPoint(x: 92, y: 140)
        let messages = bridge.window(moved)
        XCTAssertEqual(messages.first?["type"], .string("window.update"))
        messages.forEach { _ = model.apply($0) }
        XCTAssertEqual(model.windows[7]?.frame.origin, CGPoint(x: 100, y: 140))
        XCTAssertEqual(model.windows[7]?.title, "Notepad", "what the update did not bring stays")
    }

    func testHiddenWindowGoesAndComesBack() {
        var bridge = RailBridge()
        _ = bridge.window(created(7))
        var hidden = RailBridge.Order(id: 7)
        hidden.showState = 0
        XCTAssertEqual(bridge.window(hidden), [.map([("type", .string("window.destroy")), ("id", .uint(7))])])
        XCTAssertEqual(bridge.window(hidden), [], "a hidden window is taken away once")
        var shown = RailBridge.Order(id: 7)
        shown.showState = 3
        let back = bridge.window(shown)
        XCTAssertEqual(back.first?["type"], .string("window.create"))
        XCTAssertEqual(back.first?["state"], .string("maximized"))
        XCTAssertEqual(bridge.deleted(7).count, 1)
        XCTAssertEqual(bridge.deleted(7), [])
    }

    func testPopupStyleAndOwner() {
        var bridge = RailBridge()
        var menu = RailBridge.Order(id: 9, created: true)
        menu.style = 0x8000_0000
        menu.owner = 7
        menu.showState = 5
        menu.offset = .zero
        menu.size = CGSize(width: 100, height: 200)
        let message = bridge.window(menu).first
        XCTAssertEqual(message?["kind"], .string("popup"))
        XCTAssertEqual(message?["owner"], .uint(7))
    }

    func testMoveKeepsTheFrameAroundTheVisiblePart() {
        var bridge = RailBridge()
        _ = bridge.window(created(7))
        XCTAssertEqual(
            bridge.frame(of: 7, visible: CGRect(x: 500, y: 300, width: 400, height: 300)),
            CGRect(x: 492, y: 300, width: 416, height: 308))
        XCTAssertNil(bridge.frame(of: 8, visible: .zero))
    }

    func testDesktopOrderAndFocusAndIcons() {
        var bridge = RailBridge()
        _ = bridge.window(created(7))
        XCTAssertEqual(
            bridge.desktop(active: 7, order: [7, 9]),
            [
                .map([("type", .string("zorder")), ("ids", .array([.uint(7), .uint(9)]))]),
                .map([("type", .string("foreground")), ("id", .uint(7))]),
            ])
        XCTAssertEqual(bridge.icon(7, png: Data([1])).count, 1)
        XCTAssertEqual(bridge.icon(8, png: Data([1])), [], "no icon for a window the model does not have")
    }
}
