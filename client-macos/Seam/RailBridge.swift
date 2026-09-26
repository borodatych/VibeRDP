import CoreGraphics
import Foundation

/// RemoteApp in the words of the Seam protocol: the window orders of RAIL become the messages of section 6,
/// so the windows of the Mac, the focus, the moves and the Dock work over RAIL as they do over the helper
/// A window order brings only what changed; the bridge keeps each window whole and says all of it every time
struct RailBridge {
    /// A window order as the core hands it over, copied out of the call; nil fields did not come
    struct Order: Equatable, Sendable {
        var id: UInt64
        var created = false
        var owner: UInt64?
        var style: UInt32?
        var showState: UInt32?
        var title: String?
        var offset: CGPoint?
        var size: CGSize?
        var visibleOffset: CGPoint?
        var region: CGRect?
    }

    private struct Window {
        var owner: UInt64 = 0
        var style: UInt32 = 0
        var showState: UInt32 = Self.shown
        var title = ""
        var frame = CGRect.zero
        var visibleOffset: CGPoint?
        var region: CGRect?

        static let shown: UInt32 = 5

        /// What the user sees of the window: the visible region when the server described it, else its frame
        var visible: CGRect {
            guard let visibleOffset, let region, region.width > 0, region.height > 0 else { return frame }
            return region.offsetBy(dx: visibleOffset.x, dy: visibleOffset.y)
        }
    }

    /// SW_ values of Windows the protocol names
    private static let hidden: UInt32 = 0
    private static let minimized: Set<UInt32> = [2, 6, 7]
    private static let maximized: UInt32 = 3
    /// WS_POPUP without a whole caption is a menu, a tooltip or another popup, as the helper decides
    private static let popupStyle: UInt32 = 0x8000_0000
    private static let captionStyle: UInt32 = 0x00C0_0000

    private var windows: [UInt64: Window] = [:]
    /// The windows the model has been told about: a hidden one is taken away and comes back when shown
    private var announced: Set<UInt64> = []

    /// The messages one window order makes
    mutating func window(_ order: Order) -> [MessagePackValue] {
        var window = order.created ? Window() : windows[order.id] ?? Window()
        if let owner = order.owner { window.owner = owner }
        if let style = order.style { window.style = style }
        if let showState = order.showState { window.showState = showState }
        if let title = order.title { window.title = title }
        if let offset = order.offset { window.frame.origin = offset }
        if let size = order.size { window.frame.size = size }
        if let visibleOffset = order.visibleOffset { window.visibleOffset = visibleOffset }
        if let region = order.region { window.region = region }
        windows[order.id] = window

        guard window.showState != Self.hidden else {
            return announced.remove(order.id) == nil ? [] : [Self.destroy(order.id)]
        }
        let isNew = announced.insert(order.id).inserted
        return [Self.describe(order.id, window, type: isNew ? "window.create" : "window.update")]
    }

    mutating func deleted(_ id: UInt64) -> [MessagePackValue] {
        windows[id] = nil
        return announced.remove(id) == nil ? [] : [Self.destroy(id)]
    }

    func icon(_ id: UInt64, png: Data) -> [MessagePackValue] {
        guard announced.contains(id) else { return [] }
        return [.map([("type", .string("window.icon")), ("id", .uint(id)), ("png", .binary(png))])]
    }

    /// The desktop order: the window with the focus and the order top first, each when it came
    func desktop(active: UInt64?, order: [UInt64]?) -> [MessagePackValue] {
        var messages: [MessagePackValue] = []
        if let order {
            messages.append(.map([("type", .string("zorder")), ("ids", .array(order.map { .uint($0) }))]))
        }
        if let active {
            messages.append(.map([("type", .string("foreground")), ("id", .uint(active))]))
        }
        return messages
    }

    /// The rectangle RAIL moves a window to for these visible bounds: its frame keeps the margin around them
    func frame(of id: UInt64, visible target: CGRect) -> CGRect? {
        guard let window = windows[id] else { return nil }
        let visible = window.visible
        return CGRect(
            x: target.minX - (visible.minX - window.frame.minX), y: target.minY - (visible.minY - window.frame.minY),
            width: target.width + (window.frame.width - visible.width),
            height: target.height + (window.frame.height - visible.height))
    }

    private static func destroy(_ id: UInt64) -> MessagePackValue {
        .map([("type", .string("window.destroy")), ("id", .uint(id))])
    }

    private static func describe(_ id: UInt64, _ window: Window, type: String) -> MessagePackValue {
        let visible = window.visible
        let state =
            minimized.contains(window.showState) ? "minimized" : window.showState == maximized ? "maximized" : "normal"
        let popup = window.style & popupStyle != 0 && window.style & captionStyle != captionStyle
        let rect = [visible.minX, visible.minY, visible.width, visible.height].map {
            MessagePackValue.int(Int64($0.rounded()))
        }
        return .map([
            ("type", .string(type)), ("id", .uint(id)), ("owner", .uint(window.owner)), ("rect", .array(rect)),
            ("title", .string(window.title)), ("state", .string(state)), ("kind", .string(popup ? "popup" : "app")),
        ])
    }
}
