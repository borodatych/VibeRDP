import CryptoKit
import Foundation
import Security

/// The certificate chain a server presented, kept as DER so it can cross threads
struct ServerCertificate: Equatable, Sendable {
    let host: String
    let port: UInt16
    /// Server certificate first; a certificate repeated in the chain appears once
    let chain: [Data]
    /// SHA-256 of the server certificate, colon-separated uppercase hex, as Windows and OpenSSL print it
    let fingerprint: String
    /// The subject the way macOS summarizes it, usually the common name
    let subject: String

    private static let pemBegin = "-----BEGIN CERTIFICATE-----"
    private static let pemEnd = "-----END CERTIFICATE-----"

    /// Reads the PEM chain the core hands over; nil when it holds no certificate macOS can parse
    init?(host: String, port: UInt16, pem: Data) {
        var chain: [Data] = []
        var rest = Substring(String(decoding: pem, as: UTF8.self))
        while let begin = rest.range(of: Self.pemBegin),
            let end = rest.range(of: Self.pemEnd, range: begin.upperBound..<rest.endIndex)
        {
            let body = String(rest[begin.upperBound..<end.lowerBound])
            guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
            if !chain.contains(der) {
                chain.append(der)
            }
            rest = rest[end.upperBound...]
        }
        guard let leafData = chain.first, let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
            return nil
        }

        self.host = host
        self.port = port
        self.chain = chain
        self.fingerprint = SHA256.hash(data: leafData).map { String(format: "%02X", $0) }.joined(separator: ":")
        self.subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
    }

    var certificates: [SecCertificate] {
        chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
}
