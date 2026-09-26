import CoreGraphics
import Foundation

/// A window of the Windows host as the helper describes it: protocol/seam-protocol.md, section 6
struct RemoteWindow: Equatable {
    enum State: String {
        case normal, minimized, maximized
    }

    enum Kind: String {
        case app, popup
    }

    /// The HWND on the host
    let id: UInt64
    /// The owner of a popup, a menu or a tooltip; 0 for none
    var owner: UInt64 = 0
    /// Visible bounds in pixels of the Windows virtual screen, the primary monitor at 0,0
    var frame: CGRect
    var title = ""
    var state = State.normal
    var kind = Kind.app
    var pid: UInt32 = 0
    var exe = ""
    /// PNG up to 256 by 256; nil until window.icon comes
    var icon: Data?
}

/// The windows of the host, their order and the focus, kept from the messages of the helper
/// Pure: the caller feeds it the messages of a ready link and forgets it when the channel closes
struct RemoteWindows {
    /// What one message changed, for whoever shows the windows
    enum Change: Equatable {
        case created(UInt64)
        case updated(UInt64)
        case destroyed(UInt64)
        case icon(UInt64)
        case order
        case focus
    }

    /// The outcome of one message: the change, or a line for the log when the message was skipped
    struct Outcome: Equatable {
        var change: Change?
        var note: String?
    }

    private(set) var windows: [UInt64: RemoteWindow] = [:]
    /// Ids top to bottom, known windows only
    private(set) var order: [UInt64] = []
    /// The window with the focus on the host; 0 for none of the list
    private(set) var foreground: UInt64 = 0

    /// The windows top to bottom
    var ordered: [RemoteWindow] {
        order.compactMap { windows[$0] }
    }

    mutating func apply(_ message: MessagePackValue) -> Outcome {
        guard let kind = message["type"]?.string else {
            return Outcome(note: "message without a type skipped")
        }
        switch kind {
        case "window.create":
            return create(message)
        case "window.update":
            return update(message)
        case "window.destroy":
            guard let id = message["id"]?.uint64 else { return skipped(kind, "without id") }
            guard windows.removeValue(forKey: id) != nil else { return skipped(kind, "of unknown window \(id)") }
            order.removeAll { $0 == id }
            if foreground == id {
                foreground = 0
            }
            return Outcome(change: .destroyed(id))
        case "window.icon":
            guard let id = message["id"]?.uint64, let png = message["png"]?.binary else {
                return skipped(kind, "without id or png")
            }
            guard var window = windows[id] else { return skipped(kind, "of unknown window \(id)") }
            // Read and write back, not a change in place:
            // That compiles to a coroutine of the dictionary, which needs a Swift runtime newer than macOS 14
            window.icon = png
            windows[id] = window
            return Outcome(change: .icon(id))
        case "zorder":
            guard let ids = message["ids"]?.array?.compactMap(\.uint64) else { return skipped(kind, "without ids") }
            order = ids.filter { windows[$0] != nil }
            return Outcome(change: .order)
        case "foreground":
            guard let id = message["id"]?.uint64 else { return skipped(kind, "without id") }
            foreground = windows[id] != nil ? id : 0
            return Outcome(change: .focus)
        default:
            return Outcome(note: "unknown message \"\(kind)\" skipped")
        }
    }

    /// A create for a window already known replaces it: the helper sends the whole state again after a hello
    private mutating func create(_ message: MessagePackValue) -> Outcome {
        guard let id = message["id"]?.uint64, let frame = message["rect"].flatMap(Self.rect) else {
            return skipped("window.create", "without id or rect")
        }
        var window = RemoteWindow(id: id, frame: frame)
        window.icon = windows[id]?.icon
        Self.merge(message, into: &window)
        windows[id] = window
        if !order.contains(id) {
            // A new window appears on top until the next zorder says otherwise
            order.insert(id, at: 0)
        }
        return Outcome(change: .created(id))
    }

    private mutating func update(_ message: MessagePackValue) -> Outcome {
        guard let id = message["id"]?.uint64 else { return skipped("window.update", "without id") }
        guard var window = windows[id] else { return skipped("window.update", "of unknown window \(id)") }
        if let frame = message["rect"].flatMap(Self.rect) {
            window.frame = frame
        }
        Self.merge(message, into: &window)
        windows[id] = window
        return Outcome(change: .updated(id))
    }

    /// The optional keys of window.create and window.update; a missing one keeps its value
    private static func merge(_ message: MessagePackValue, into window: inout RemoteWindow) {
        if let owner = message["owner"]?.uint64 {
            window.owner = owner
        }
        if let title = message["title"]?.string {
            window.title = title
        }
        if let state = message["state"]?.string.flatMap(RemoteWindow.State.init) {
            window.state = state
        }
        if let kind = message["kind"]?.string.flatMap(RemoteWindow.Kind.init) {
            window.kind = kind
        }
        if let pid = message["pid"]?.uint64.flatMap({ UInt32(exactly: $0) }) {
            window.pid = pid
        }
        if let exe = message["exe"]?.string {
            window.exe = exe
        }
    }

    /// [x, y, width, height] of i32, with a size that is not negative
    private static func rect(_ value: MessagePackValue) -> CGRect? {
        guard let items = value.array, items.count == 4 else { return nil }
        let numbers = items.compactMap { $0.int64.flatMap { Int32(exactly: $0) } }
        guard numbers.count == 4, numbers[2] >= 0, numbers[3] >= 0 else { return nil }
        return CGRect(x: Int(numbers[0]), y: Int(numbers[1]), width: Int(numbers[2]), height: Int(numbers[3]))
    }

    private func skipped(_ kind: String, _ reason: String) -> Outcome {
        Outcome(note: "\(kind) \(reason) skipped")
    }
}
