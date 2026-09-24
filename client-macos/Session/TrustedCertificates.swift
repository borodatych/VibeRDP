import Foundation

/// Certificates the user chose to remember: one fingerprint per host and port
/// A fingerprint is no secret, so it lives in the app defaults rather than in the Keychain
@MainActor
final class TrustedCertificates {
    static let defaultsKey = "trustedCertificates"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func fingerprint(host: String, port: UInt16) -> String? {
        stored[Self.key(host: host, port: port)]
    }

    func remember(_ fingerprint: String, host: String, port: UInt16) {
        var all = stored
        all[Self.key(host: host, port: port)] = fingerprint
        defaults.set(all, forKey: Self.defaultsKey)
    }

    private var stored: [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// Host names are case-insensitive; an IPv6 address goes in brackets, so the port stays unambiguous
    static func key(host: String, port: UInt16) -> String {
        let name = host.lowercased()
        return name.contains(":") ? "[\(name)]:\(port)" : "\(name):\(port)"
    }
}
