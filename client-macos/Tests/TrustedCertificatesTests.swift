import XCTest

@testable import VibeRDP

/// Each test gets a defaults domain of its own, so the app's remembered certificates stay untouched
@MainActor
final class TrustedCertificatesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRememberedFingerprintIsFoundByHostAndPort() {
        let store = TrustedCertificates(defaults: defaults)
        XCTAssertNil(store.fingerprint(host: "win.corp", port: 3389))

        store.remember("AA", host: "Win.Corp", port: 3389)
        XCTAssertEqual(store.fingerprint(host: "win.corp", port: 3389), "AA")
        XCTAssertNil(store.fingerprint(host: "win.corp", port: 3390))
        XCTAssertEqual(TrustedCertificates(defaults: defaults).fingerprint(host: "WIN.CORP", port: 3389), "AA")
    }

    func testNewFingerprintReplacesTheOld() {
        let store = TrustedCertificates(defaults: defaults)
        store.remember("AA", host: "h", port: 1)
        store.remember("BB", host: "h", port: 1)
        XCTAssertEqual(store.fingerprint(host: "h", port: 1), "BB")
    }

    func testIPv6KeyKeepsThePortApart() {
        XCTAssertEqual(TrustedCertificates.key(host: "FE80::1", port: 3389), "[fe80::1]:3389")
        XCTAssertEqual(TrustedCertificates.key(host: "10.0.0.5", port: 3389), "10.0.0.5:3389")
    }
}
