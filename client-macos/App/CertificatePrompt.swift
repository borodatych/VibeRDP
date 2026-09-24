import AppKit

/// The question about a certificate macOS does not trust
/// For a changed certificate the safe answer comes first, so Return cancels
@MainActor
enum CertificatePrompt {
    static func alert(for certificate: ServerCertificate, verdict: CertificateVerdict) -> NSAlert {
        let alert = NSAlert()
        let host = ["host": certificate.host]
        let details = Localization.text(
            .certificateDetails, ["subject": certificate.subject, "fingerprint": certificate.fingerprint])
        let advice = Localization.text(.certificateAdvice)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = Localization.text(.certificateRemember)

        switch verdict {
        case .changed(let problem):
            alert.alertStyle = .critical
            alert.messageText = Localization.text(.certificateChangedTitle, host)
            alert.informativeText = [
                Localization.text(.certificateChangedWarning), text(for: problem), details, advice,
            ].joined(separator: "\n\n")
            alert.addButton(withTitle: Localization.text(.certificateActionCancel))
            alert.addButton(withTitle: Localization.text(.certificateActionConnectAnyway))
        case .unknown(let problem):
            alert.alertStyle = .warning
            alert.messageText = Localization.text(.certificateUnknownTitle, host)
            alert.informativeText = [text(for: problem), details, advice].joined(separator: "\n\n")
            alert.addButton(withTitle: Localization.text(.certificateActionConnect))
            alert.addButton(withTitle: Localization.text(.certificateActionCancel))
        case .trusted, .remembered:
            preconditionFailure("a trusted certificate needs no question")
        }
        return alert
    }

    /// Which button of the alert connects
    static func accepts(_ response: NSApplication.ModalResponse, verdict: CertificateVerdict) -> Bool {
        switch verdict {
        case .changed: response == .alertSecondButtonReturn
        case .unknown, .trusted, .remembered: response == .alertFirstButtonReturn
        }
    }

    static func text(for problem: TrustProblem) -> String {
        switch problem {
        case .untrustedIssuer: Localization.text(.certificateProblemUntrustedIssuer)
        case .nameMismatch: Localization.text(.certificateProblemNameMismatch)
        case .expired: Localization.text(.certificateProblemExpired)
        case .other(let status): Localization.text(.certificateProblemOther, ["code": String(status)])
        }
    }
}
