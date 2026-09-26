import XCTest

@testable import VibeRDP

/// The Seam codec against the bytes the helper writes, helper-win/src/protocol.rs, and the link against the clock
final class SeamTests: XCTestCase {
    private func ping(_ seq: UInt64) -> MessagePackValue {
        .map([("type", .string("ping")), ("seq", .uint(seq))])
    }

    /// The example of the specification, the same bytes the Rust tests check
    func testKnownBytes() throws {
        let bytes = MessagePack.encode(ping(7))
        let expected: [UInt8] = [0x82, 0xa4, 0x74, 0x79, 0x70, 0x65, 0xa4, 0x70, 0x69, 0x6e, 0x67, 0xa3, 0x73, 0x65, 0x71, 0x07]
        XCTAssertEqual([UInt8](bytes), expected)
        XCTAssertEqual(try MessagePack.decode(bytes), ping(7))
    }

    func testValuesRoundTrip() throws {
        let values: [MessagePackValue] = [
            .null, .bool(true), .uint(0), .uint(127), .uint(128), .uint(65_536), .uint(.max),
            .int(-1), .int(-33), .int(-40_000), .int(.min), .float(1.5),
            .string("Книга1 - Excel"), .string(String(repeating: "x", count: 300)),
            .binary(Data([0x89, 0x50, 0x4e, 0x47])), .array((0 ..< 20).map { .uint($0) }),
            .map([("id", .uint(132_290)), ("rect", .array([.int(-6016), .int(0), .int(1280), .int(800)]))]),
        ]
        for value in values {
            XCTAssertEqual(try MessagePack.decode(MessagePack.encode(value)), value, "\(value)")
        }
    }

    func testBadInput() {
        func error(_ bytes: [UInt8]) -> MessagePackError? {
            do {
                _ = try MessagePack.decode(Data(bytes))
                return nil
            } catch {
                return error as? MessagePackError
            }
        }
        XCTAssertEqual(error([0xa5, 0x61]), .truncated)
        XCTAssertEqual(error([0x81, 0x01, 0x02]), .unsupported(0x01))
        XCTAssertEqual(error([0xc0, 0xc0]), .trailingBytes)
        XCTAssertEqual(error([0xdd, 0xff, 0xff, 0xff, 0xff]), .truncated, "a lying count")
        XCTAssertEqual(error([0xc1]), .unsupported(0xc1))
    }

    private func hello(version: UInt64, capabilities: [String] = ["windows", "icons"]) -> Data {
        MessagePack.encode(
            .map([
                ("type", .string("hello")), ("version", .uint(version)),
                ("capabilities", .array(capabilities.map { .string($0) })),
                ("agent", .string("vibe-seam-helper 0.1.0")),
            ]))
    }

    func testGreetingMakesTheLinkReady() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let sent = link.opened(at: start)
        XCTAssertEqual(sent.first?["type"], .string("hello"))
        XCTAssertEqual(sent.first?["version"], .uint(1))
        XCTAssertEqual(link.state, .greeting)
        _ = link.received(hello(version: 1), at: start + 1)
        XCTAssertEqual(link.state, .ready(agent: "vibe-seam-helper 0.1.0", capabilities: ["windows", "icons"]))
    }

    func testNoHelloInTimeLeavesTheDesktop() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        let start = Date(timeIntervalSinceReferenceDate: 0)
        _ = link.opened(at: start)
        XCTAssertEqual(link.tick(at: start + 1.9), [])
        XCTAssertEqual(link.state, .greeting)
        _ = link.tick(at: start + 2)
        XCTAssertEqual(link.state, .silent)
        _ = link.received(hello(version: 1), at: start + 3)
        XCTAssertEqual(link.state, .silent, "a late hello does not bring the link up")
    }

    func testOtherVersionIsIncompatible() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        _ = link.opened(at: Date())
        _ = link.received(hello(version: 2), at: Date())
        XCTAssertEqual(link.state, .incompatible(version: 2))
    }

    func testPingsAndTheirTimeout() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        let start = Date(timeIntervalSinceReferenceDate: 0)
        _ = link.opened(at: start)
        _ = link.received(hello(version: 1), at: start)
        XCTAssertEqual(link.tick(at: start + 9), [])
        XCTAssertEqual(link.tick(at: start + 10), [ping(1)])
        XCTAssertEqual(link.tick(at: start + 15), [])
        _ = link.received(MessagePack.encode(.map([("type", .string("pong")), ("seq", .uint(1))])), at: start + 15)
        XCTAssertEqual(link.tick(at: start + 20), [ping(2)])
        _ = link.tick(at: start + 44)
        XCTAssertNotEqual(link.state, .lost)
        _ = link.tick(at: start + 45)
        XCTAssertEqual(link.state, .lost)
    }

    func testMessagesPassOnlyOnAReadyLink() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: [])
        let window = MessagePackValue.map([("type", .string("window.destroy")), ("id", .uint(5))])
        _ = link.opened(at: Date())
        XCTAssertNil(link.received(MessagePack.encode(window), at: Date()).message)
        _ = link.received(hello(version: 1), at: Date())
        XCTAssertEqual(link.received(MessagePack.encode(window), at: Date()).message, window)
        XCTAssertNotNil(link.received(Data([0xc1]), at: Date()).note)
    }
}
