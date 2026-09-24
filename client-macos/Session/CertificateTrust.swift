import Foundation
import Security

/// Why macOS did not trust a certificate
enum TrustProblem: Equatable, Sendable {
    case untrustedIssuer
    case nameMismatch
    case expired
    case other(OSStatus)
}

/// What macOS thinks of the chain: the system and corporate roots of the Keychain decide
enum SystemTrust: Equatable, Sendable {
    case trusted
    case untrusted(TrustProblem)
}

/// What to do with a server certificate
enum CertificateVerdict: Equatable, Sendable {
    /// macOS trusts the chain for this host
    case trusted
    /// The user remembered this very certificate for this host and port
    case remembered
    /// Not trusted and never seen: the user decides
    case unknown(TrustProblem)
    /// Not trusted and different from the one the user remembered: the user decides, warned
    case changed(TrustProblem)

    var acceptsWithoutAsking: Bool {
        switch self {
        case .trusted, .remembered: true
        case .unknown, .changed: false
        }
    }
}

enum CertificateTrust {
    static func verdict(system: SystemTrust, remembered: String?, fingerprint: String) -> CertificateVerdict {
        switch system {
        case .trusted:
            return .trusted
        case .untrusted(let problem):
            guard let remembered else { return .unknown(problem) }
            return remembered == fingerprint ? .remembered : .changed(problem)
        }
    }

    /// Evaluates the chain for the host with the SSL policy; blocks on revocation checks, so never on the main thread
    static func evaluate(_ certificate: ServerCertificate) -> SystemTrust {
        let policy = SecPolicyCreateSSL(true, certificate.host as CFString)
        var trust: SecTrust?
        let created = SecTrustCreateWithCertificates(certificate.certificates as CFArray, policy, &trust)
        guard created == errSecSuccess, let trust else { return .untrusted(.other(created)) }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return .trusted
        }
        return .untrusted(problem(for: OSStatus(error.map(CFErrorGetCode) ?? Int(errSecNotTrusted))))
    }

    /// macOS reports the most significant failure of the chain as one status code
    static func problem(for status: OSStatus) -> TrustProblem {
        switch status {
        case errSecNotTrusted, errSecCreateChainFailed:
            return .untrustedIssuer
        case errSecHostNameMismatch:
            return .nameMismatch
        case errSecCertificateExpired, errSecCertificateNotValidYet:
            return .expired
        default:
            return .other(status)
        }
    }
}
