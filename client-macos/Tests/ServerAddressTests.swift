import XCTest

@testable import VibeRDP

final class ServerAddressTests: XCTestCase {
    func testHostAlone() {
        XCTAssertEqual(ServerAddress("  win.corp.local "), ServerAddress(host: "win.corp.local", port: nil))
    }

    func testHostWithPort() {
        XCTAssertEqual(ServerAddress("10.0.0.5:3390"), ServerAddress(host: "10.0.0.5", port: 3390))
    }

    func testBareIPv6KeepsItsColons() {
        XCTAssertEqual(ServerAddress("fe80::1"), ServerAddress(host: "fe80::1", port: nil))
    }

    func testBracketedIPv6WithAndWithoutPort() {
        XCTAssertEqual(ServerAddress("[fe80::1]:3390"), ServerAddress(host: "fe80::1", port: 3390))
        XCTAssertEqual(ServerAddress("[fe80::1]"), ServerAddress(host: "fe80::1", port: nil))
    }

    func testRejectsWhatCannotBeAnAddress() {
        for text in ["", "   ", "host:", "host:0", "host:65536", "host:abc", ":3389", "[fe80::1", "[fe80::1]x", "a b"] {
            XCTAssertNil(ServerAddress(text), "\"\(text)\" must be rejected")
        }
    }
}

extension ServerAddress {
    fileprivate init(host: String, port: UInt16?) {
        self = ServerAddress(port.map { "[\(host)]:\($0)" } ?? "[\(host)]")!
    }
}
