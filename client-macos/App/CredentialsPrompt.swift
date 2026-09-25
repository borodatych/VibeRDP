import AppKit
import VibeRDPCore

/// The question for a user name and a password: while the engine waits for them, or after a wrong password
@MainActor
final class CredentialsPrompt {
    static let fieldWidth: CGFloat = 260

    let alert = NSAlert()
    let userField = NSTextField()
    let passwordField = NSSecureTextField()

    /// retry says the server just turned the password down
    init(target: VRCCredentialsTarget, host: String, username: String, remember: Bool, retry: Bool) {
        let title: TextKey =
            switch target {
            case .server: .credentialsTitleServer
            case .gateway: .credentialsTitleGateway
            }
        alert.messageText = Localization.text(title, ["host": host])
        alert.informativeText = Localization.text(retry ? .credentialsMessageRetry : .credentialsMessageAsk)
        alert.alertStyle = retry ? .warning : .informational
        alert.addButton(withTitle: Localization.text(.credentialsActionSignIn))
        alert.addButton(withTitle: Localization.text(.credentialsActionCancel))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = Localization.text(.profilePasswordRemember)
        alert.suppressionButton?.state = remember ? .on : .off

        userField.stringValue = username
        userField.placeholderString = Localization.text(.connectionUserPlaceholder)
        for field in [userField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: Localization.text(.connectionUserLabel)), userField],
            [NSTextField(labelWithString: Localization.text(.connectionPasswordLabel)), passwordField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        // The name is usually known, so typing starts in the password
        alert.window.initialFirstResponder = username.isEmpty ? userField : passwordField
    }

    /// What the user entered; nil when the answer was not the Sign In button
    func answer(for response: NSApplication.ModalResponse) -> (username: String, password: String, remember: Bool)? {
        guard response == .alertFirstButtonReturn else { return nil }
        return (userField.stringValue, passwordField.stringValue, alert.suppressionButton?.state == .on)
    }
}
