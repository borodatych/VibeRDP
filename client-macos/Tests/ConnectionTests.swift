import AppKit
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

    /// The whole path from the session thread to the main thread: a failed connection arrives in order
    /// The events reach the main actor through tasks, so the test suspends for them instead of blocking the thread
    /// A name in the reserved .invalid zone fails at resolution, before any socket: an app that opens one
    /// is subject to the Local Network privilege, and on a CI runner nobody answers its alert
    func testUnresolvableHostReportsHostNotFound() async throws {
        var events: [SessionController.Event] = []
        let ended = expectation(description: "Disconnected")
        let controller = SessionController(trusted: TrustedCertificates(defaults: defaults)) { event in
            events.append(event)
            if event == .state(.disconnected) {
                ended.fulfill()
            }
        }

        let address = try XCTUnwrap(ServerAddress("viberdp-test.invalid"))
        let desktop = CGSize(width: 1024, height: 768)
        XCTAssertTrue(controller.connect(to: address, username: "", password: "", desktop: desktop))
        await fulfillment(of: [ended], timeout: 10)

        XCTAssertEqual(events.first, .state(.connecting))
        XCTAssertEqual(events.last, .state(.disconnected))
        let notFound = events.contains { if case .failed(.hostNotFound, _) = $0 { true } else { false } }
        XCTAssertTrue(notFound, "\(events)")
        XCTAssertFalse(
            controller.connect(to: address, username: "", password: "", desktop: desktop), "a controller connects once")
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

    /// Without a session there is nothing to end: the menu item stays grey
    func testDisconnectCommandNeedsASession() {
        let form = ConnectionViewController(trusted: TrustedCertificates(defaults: defaults))
        form.loadView()
        XCTAssertFalse(form.validateMenuItem(Self.disconnectCommand))
    }

    /// From the start of a connection the menu item ends it, and once the session is over the item is grey again
    func testDisconnectCommandEndsTheSession() async throws {
        guard FrameRenderer() != nil else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        let form = ConnectionViewController(trusted: TrustedCertificates(defaults: defaults))
        form.loadView()
        form.hostField.stringValue = "viberdp-test.invalid"
        form.toggleConnection()
        XCTAssertTrue(form.validateMenuItem(Self.disconnectCommand))
        XCTAssertFalse(form.hostField.isEnabled)

        form.disconnect(nil)
        // The session ends on its own thread, and Disconnected reaches the form through the main actor
        let deadline = Date().addingTimeInterval(10)
        while form.validateMenuItem(Self.disconnectCommand) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(form.validateMenuItem(Self.disconnectCommand))
        XCTAssertTrue(form.hostField.isEnabled)
    }

    private static var disconnectCommand: NSMenuItem {
        NSMenuItem(title: "", action: #selector(ConnectionViewController.disconnect(_:)), keyEquivalent: "")
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
}
