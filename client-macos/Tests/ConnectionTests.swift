import AppKit
import Darwin
import VibeRDPCore
import XCTest

@testable import VibeRDP

@MainActor
final class ConnectionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The whole path from the session thread to the main thread: a refused connection arrives in order
    func testRefusedConnectionReportsUnreachable() throws {
        var events: [SessionController.Event] = []
        let ended = expectation(description: "Disconnected")
        let controller = SessionController(trusted: TrustedCertificates(defaults: defaults)) { event in
            events.append(event)
            if event == .state(.disconnected) {
                ended.fulfill()
            }
        }

        let address = try XCTUnwrap(ServerAddress("127.0.0.1:\(Self.unusedPort())"))
        XCTAssertTrue(controller.connect(to: address, username: "", password: ""))
        wait(for: [ended], timeout: 10)

        XCTAssertEqual(events.first, .state(.connecting))
        XCTAssertEqual(events.last, .state(.disconnected))
        let unreachable = events.contains { if case .failed(.unreachable, _) = $0 { true } else { false } }
        XCTAssertTrue(unreachable, "\(events)")
        XCTAssertFalse(controller.connect(to: address, username: "", password: ""), "a controller connects once")
    }

    func testFormRefusesAnEmptyHost() {
        let form = ConnectionViewController(trusted: TrustedCertificates(defaults: defaults))
        form.loadView()
        form.hostField.stringValue = "  "
        form.toggleConnection()
        XCTAssertEqual(form.statusLabel.stringValue, Localization.text(.connectionStatusInvalidHost))
        XCTAssertEqual(form.connectButton.title, Localization.text(.connectionActionConnect))
        XCTAssertTrue(form.hostField.isEnabled)
    }

    func testErrorMessagesNameTheHostAndKeepTheEngineCode() {
        let code = "ERRCONNECT_CONNECT_FAILED"
        let reason = Localization.text(.connectionErrorUnreachable, ["host": "win"])
        XCTAssertEqual(
            ConnectionViewController.message(for: .unreachable, name: code, host: "win"),
            Localization.text(.connectionErrorDetails, ["message": reason, "code": code]))
        XCTAssertEqual(
            ConnectionViewController.message(for: .authentication, name: "", host: "win"),
            Localization.text(.connectionErrorAuthentication))
    }

    /// For a changed certificate Return must not connect: the safe answer is the first button
    func testChangedCertificatePutsCancelFirst() throws {
        let pem = Data(Fixtures.certificatePEM.utf8)
        let certificate = try XCTUnwrap(ServerCertificate(host: "vibe.test", port: 3389, pem: pem))
        let changed = CertificatePrompt.alert(for: certificate, verdict: .changed(.untrustedIssuer))
        XCTAssertEqual(changed.buttons.first?.title, Localization.text(.certificateActionCancel))
        XCTAssertFalse(CertificatePrompt.accepts(.alertFirstButtonReturn, verdict: .changed(.untrustedIssuer)))
        XCTAssertTrue(CertificatePrompt.accepts(.alertSecondButtonReturn, verdict: .changed(.untrustedIssuer)))

        let unknown = CertificatePrompt.alert(for: certificate, verdict: .unknown(.untrustedIssuer))
        XCTAssertEqual(unknown.buttons.first?.title, Localization.text(.certificateActionConnect))
        XCTAssertTrue(unknown.informativeText.contains(Fixtures.certificateFingerprint))
        XCTAssertTrue(CertificatePrompt.accepts(.alertFirstButtonReturn, verdict: .unknown(.untrustedIssuer)))
        XCTAssertFalse(CertificatePrompt.accepts(.abort, verdict: .unknown(.untrustedIssuer)))
    }

    /// A loopback port that was free a moment ago: connecting to it is refused
    private static func unusedPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        // Darwin.bind: inside an NSObject subclass a bare bind names the Cocoa bindings method
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
