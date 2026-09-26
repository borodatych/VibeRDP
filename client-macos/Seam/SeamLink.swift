import CoreGraphics
import Foundation

/// The client side of a conversation over the Seam channel: greeting, versions and liveness, sections 4 and 9
/// of protocol/seam-protocol.md
/// Pure: the caller gives it the bodies, the time and the ticks, and sends what it returns
struct SeamLink {
    /// The major version both sides must share
    static let version: UInt64 = 1
    /// How long the helper has to say hello after the channel opens
    static let helloTimeout: TimeInterval = 2
    static let pingInterval: TimeInterval = 10
    /// No pong for this long: the helper is gone
    static let pongTimeout: TimeInterval = 30

    enum State: Equatable {
        /// No channel: the session is a desktop
        case closed
        /// The channel opened and the client said hello; the helper has not answered yet
        case greeting
        /// The helper speaks our version and can do these: section 5 of the specification names them
        case ready(agent: String, capabilities: Set<String>)
        /// The helper speaks another version: the two do not talk
        case incompatible(version: UInt64)
        /// The helper said nothing in time: the session stays a desktop, without a word to the user
        case silent
        /// The helper stopped answering pings
        case lost
    }

    /// What the client asks of a window of the host: section 7 of the specification
    enum Command: Equatable {
        case activate
        /// New visible bounds in pixels of Windows
        case move(CGRect)
        case minimize, maximize, restore, close

        var action: String {
            switch self {
            case .activate: "activate"
            case .move: "move"
            case .minimize: "minimize"
            case .maximize: "maximize"
            case .restore: "restore"
            case .close: "close"
            }
        }
    }

    /// What one body brought: replies to send, a message for the rest of the app, a line for the log
    struct Outcome: Equatable {
        var message: MessagePackValue?
        var note: String?
    }

    let agent: String
    let capabilities: [String]
    private(set) var state = State.closed
    private var openedAt = Date.distantPast
    private var lastPong = Date.distantPast
    private var lastPing = Date.distantPast
    private var nextSeq: UInt32 = 1

    init(agent: String, capabilities: [String]) {
        self.agent = agent
        self.capabilities = capabilities
    }

    /// The channel opened: the client greets first
    mutating func opened(at now: Date) -> [MessagePackValue] {
        state = .greeting
        openedAt = now
        nextSeq = 1
        return [
            .map([
                ("type", .string("hello")),
                ("version", .uint(Self.version)),
                ("capabilities", .array(capabilities.map { .string($0) })),
                ("agent", .string(agent)),
            ])
        ]
    }

    mutating func closed() {
        state = .closed
    }

    /// One body of the helper
    mutating func received(_ body: Data, at now: Date) -> Outcome {
        let value: MessagePackValue
        do {
            value = try MessagePack.decode(body)
        } catch {
            return Outcome(note: "body of \(body.count) bytes not decoded: \(error)")
        }
        guard let kind = value["type"]?.string else {
            return Outcome(note: "message without a type skipped")
        }
        if kind == "hello" {
            return greet(value, at: now)
        }
        guard case .ready = state else {
            return Outcome(note: "\"\(kind)\" outside a ready channel skipped")
        }
        switch kind {
        case "pong":
            lastPong = now
            return Outcome()
        // The windows show what a command did: an answer only matters when it says the command failed
        case "ack":
            return Outcome()
        case "error":
            let seq = value["seq"]?.uint64.map(String.init) ?? "?"
            let code = value["code"]?.string ?? "unknown"
            let detail = value["message"]?.string.map { ": \($0)" } ?? ""
            return Outcome(note: "command \(seq) failed, \(code)\(detail)")
        default:
            break
        }
        return Outcome(message: value)
    }

    /// A command for a window of the host; nil while the link is not ready
    mutating func command(_ command: Command, window id: UInt64) -> MessagePackValue? {
        guard case .ready = state else { return nil }
        var entries: [(String, MessagePackValue)] = [
            ("type", .string("command")), ("seq", .uint(UInt64(nextSeq))), ("id", .uint(id)),
            ("action", .string(command.action)),
        ]
        if case .move(let rect) = command {
            let numbers = [rect.minX, rect.minY, rect.width, rect.height].map { MessagePackValue.int(Int64($0.rounded())) }
            entries.append(("rect", .array(numbers)))
        }
        nextSeq &+= 1
        return .map(entries)
    }

    /// Asks the helper for the programs of its Start menu; nil while the link is not ready
    mutating func appsRequest() -> MessagePackValue? {
        request("apps.request", [])
    }

    /// Asks the helper to start a program of its Start menu; nil while the link is not ready
    mutating func launch(_ id: String) -> MessagePackValue? {
        request("launch", [("id", .string(id))])
    }

    /// Asks the helper to switch the window with the focus to a layout of this language; nil while not ready
    mutating func layout(_ language: String) -> MessagePackValue? {
        request("input.layout", [("language", .string(language))])
    }

    private mutating func request(_ type: String, _ entries: [(String, MessagePackValue)]) -> MessagePackValue? {
        guard case .ready = state else { return nil }
        defer { nextSeq &+= 1 }
        return .map([("type", .string(type)), ("seq", .uint(UInt64(nextSeq)))] + entries)
    }

    /// The clock moved: a ping when one is due, and the timeouts of the greeting and of the pongs
    mutating func tick(at now: Date) -> [MessagePackValue] {
        switch state {
        case .greeting where now.timeIntervalSince(openedAt) >= Self.helloTimeout:
            state = .silent
        case .ready where now.timeIntervalSince(lastPong) >= Self.pongTimeout:
            state = .lost
        case .ready where now.timeIntervalSince(lastPing) >= Self.pingInterval:
            lastPing = now
            defer { nextSeq &+= 1 }
            return [.map([("type", .string("ping")), ("seq", .uint(UInt64(nextSeq)))])]
        default:
            break
        }
        return []
    }

    private mutating func greet(_ hello: MessagePackValue, at now: Date) -> Outcome {
        guard state == .greeting else {
            return Outcome(note: "hello outside the greeting skipped")
        }
        guard let version = hello["version"]?.uint64 else {
            return Outcome(note: "hello without version skipped")
        }
        let agent = hello["agent"]?.string ?? "unknown helper"
        guard version == Self.version else {
            state = .incompatible(version: version)
            return Outcome(note: "helper \(agent) speaks version \(version), the client \(Self.version)")
        }
        // Each side names what it does itself, so the helper's list is kept as it came, not intersected with ours
        let theirs = Set((hello["capabilities"]?.array ?? []).compactMap(\.string))
        state = .ready(agent: agent, capabilities: theirs)
        // The first ping goes a full interval later; the greeting counts as the first sign of life
        lastPong = now
        lastPing = now
        return Outcome(note: "helper \(agent) is ready: \(theirs.sorted().joined(separator: ", "))")
    }
}
