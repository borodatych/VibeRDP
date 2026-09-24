import Security
import XCTest

@testable import VibeRDP

final class CertificateTrustTests: XCTestCase {
    private func fixture(host: String = "vibe.test") throws -> ServerCertificate {
        try XCTUnwrap(ServerCertificate(host: host, port: 3389, pem: Data(Fixtures.certificatePEM.utf8)))
    }

    func testPemChainIsParsedAndFingerprinted() throws {
        let certificate = try fixture()
        XCTAssertEqual(certificate.chain.count, 1)
        XCTAssertEqual(certificate.fingerprint, Fixtures.certificateFingerprint)
        XCTAssertEqual(certificate.subject, "vibe.test")
    }

    /// OpenSSL hands over the server certificate and then the peer chain, which starts with it again
    func testRepeatedCertificateAppearsOnce() throws {
        let doubled = Data((Fixtures.certificatePEM + "\n" + Fixtures.certificatePEM).utf8)
        let certificate = try XCTUnwrap(ServerCertificate(host: "vibe.test", port: 3389, pem: doubled))
        XCTAssertEqual(certificate.chain.count, 1)
    }

    func testUnreadablePemIsRejected() {
        XCTAssertNil(ServerCertificate(host: "h", port: 1, pem: Data()))
        XCTAssertNil(ServerCertificate(host: "h", port: 1, pem: Data("no certificate here".utf8)))
        let broken = "-----BEGIN CERTIFICATE-----\nnot base64 at all!\n-----END CERTIFICATE-----"
        XCTAssertNil(ServerCertificate(host: "h", port: 1, pem: Data(broken.utf8)))
    }

    /// Even under another name the missing trust is what macOS reports
    func testSelfSignedCertificateIsNotTrustedByMacOS() throws {
        XCTAssertEqual(CertificateTrust.evaluate(try fixture()), .untrusted(.untrustedIssuer))
        XCTAssertEqual(CertificateTrust.evaluate(try fixture(host: "other.test")), .untrusted(.untrustedIssuer))
    }

    func testVerdictFollowsSystemTrustThenTheRememberedFingerprint() {
        let problem = TrustProblem.untrustedIssuer
        let untrusted = SystemTrust.untrusted(problem)
        XCTAssertEqual(CertificateTrust.verdict(system: .trusted, remembered: nil, fingerprint: "A"), .trusted)
        XCTAssertEqual(CertificateTrust.verdict(system: .trusted, remembered: "B", fingerprint: "A"), .trusted)
        XCTAssertEqual(
            CertificateTrust.verdict(system: untrusted, remembered: nil, fingerprint: "A"), .unknown(problem))
        XCTAssertEqual(CertificateTrust.verdict(system: untrusted, remembered: "A", fingerprint: "A"), .remembered)
        XCTAssertEqual(
            CertificateTrust.verdict(system: untrusted, remembered: "B", fingerprint: "A"), .changed(problem))
    }

    func testOnlyTrustedAndRememberedPassWithoutAQuestion() {
        XCTAssertTrue(CertificateVerdict.trusted.acceptsWithoutAsking)
        XCTAssertTrue(CertificateVerdict.remembered.acceptsWithoutAsking)
        XCTAssertFalse(CertificateVerdict.unknown(.expired).acceptsWithoutAsking)
        XCTAssertFalse(CertificateVerdict.changed(.expired).acceptsWithoutAsking)
    }

    func testStatusCodesMapToProblems() {
        XCTAssertEqual(CertificateTrust.problem(for: errSecNotTrusted), .untrustedIssuer)
        XCTAssertEqual(CertificateTrust.problem(for: errSecHostNameMismatch), .nameMismatch)
        XCTAssertEqual(CertificateTrust.problem(for: errSecCertificateExpired), .expired)
        XCTAssertEqual(CertificateTrust.problem(for: errSecCertificateNotValidYet), .expired)
        XCTAssertEqual(CertificateTrust.problem(for: errSecParam), .other(errSecParam))
    }
}
