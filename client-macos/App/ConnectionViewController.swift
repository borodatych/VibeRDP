import AppKit
import VibeRDPCore

/// Content of the main window until the session view arrives (roadmap 1.2): where to connect and how it goes
@MainActor
final class ConnectionViewController: NSViewController {
    static let fieldWidth: CGFloat = 320
    static let statusWidth: CGFloat = 440
    static let spacing: CGFloat = 16

    let hostField = NSTextField()
    let userField = NSTextField()
    let passwordField = NSSecureTextField()
    let connectButton = NSButton()
    let statusLabel = NSTextField(wrappingLabelWithString: "")

    private let trusted: TrustedCertificates
    private var session: SessionController?
    private var host = ""
    /// Why the session ended: the error comes right before Disconnected, and Disconnected shows it
    private var failure: String?

    init(trusted: TrustedCertificates) {
        self.trusted = trusted
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view controller is built in code")
    }

    override func loadView() {
        hostField.placeholderString = Localization.text(.connectionHostPlaceholder)
        userField.placeholderString = Localization.text(.connectionUserPlaceholder)
        for field in [hostField, userField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }

        let grid = NSGridView(views: [
            [label(.connectionHostLabel), hostField],
            [label(.connectionUserLabel), userField],
            [label(.connectionPasswordLabel), passwordField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        connectButton.bezelStyle = .push
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        statusLabel.alignment = .center
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.statusWidth).isActive = true

        let stack = NSStackView(views: [grid, connectButton, statusLabel])
        stack.orientation = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(origin: .zero, size: MainWindow.defaultSize))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        setEditing(true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(hostField)
    }

    @objc func toggleConnection() {
        if let session {
            session.disconnect()
        } else {
            connect()
        }
    }

    private func connect() {
        guard let address = ServerAddress(hostField.stringValue) else {
            statusLabel.stringValue = Localization.text(.connectionStatusInvalidHost)
            return
        }

        let controller = SessionController(trusted: trusted) { [weak self] event in
            self?.handle(event)
        }
        host = address.host
        failure = nil
        session = controller
        setEditing(false)
        if !controller.connect(to: address, username: userField.stringValue, password: passwordField.stringValue) {
            session = nil
            setEditing(true)
            statusLabel.stringValue = Localization.text(.connectionStatusStartFailed, ["host": host])
        }
    }

    private func handle(_ event: SessionController.Event) {
        switch event {
        case .state(.connecting):
            statusLabel.stringValue = Localization.text(.connectionStatusConnecting, ["host": host])
        case .state(.connected):
            statusLabel.stringValue = Localization.text(.connectionStatusConnected, ["host": host])
        case .state(.disconnected):
            closeCertificateQuestion()
            session = nil
            setEditing(true)
            statusLabel.stringValue = failure ?? Localization.text(.connectionStatusDisconnected, ["host": host])
        case .state:
            break
        case .failed(let kind, let name):
            failure = Self.message(for: kind, name: name, host: host)
        case .certificateQuestion(let certificate, let verdict):
            ask(about: certificate, verdict: verdict)
        }
    }

    private func ask(about certificate: ServerCertificate, verdict: CertificateVerdict) {
        guard let window = view.window else {
            session?.answerCertificate(accept: false, remember: false)
            return
        }
        let alert = CertificatePrompt.alert(for: certificate, verdict: verdict)
        alert.beginSheetModal(for: window) { [weak self] response in
            let accept = CertificatePrompt.accepts(response, verdict: verdict)
            let remember = alert.suppressionButton?.state == .on
            MainActor.assumeIsolated {
                self?.session?.answerCertificate(accept: accept, remember: remember)
            }
        }
    }

    /// The session ended while the question was open: the question has nothing left to answer
    private func closeCertificateQuestion() {
        if let window = view.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .abort)
        }
    }

    private func setEditing(_ editable: Bool) {
        for field in [hostField, userField, passwordField] {
            field.isEnabled = editable
        }
        connectButton.title = Localization.text(editable ? .connectionActionConnect : .connectionActionDisconnect)
    }

    private func label(_ key: TextKey) -> NSTextField {
        NSTextField(labelWithString: Localization.text(key))
    }

    /// The reason in the app's words; the engine name of the error stays as a code for support
    static func message(for kind: VRCErrorKind, name: String, host: String) -> String {
        let key: TextKey =
            switch kind {
            case .hostNotFound: .connectionErrorHostNotFound
            case .unreachable: .connectionErrorUnreachable
            case .connectionLost: .connectionErrorConnectionLost
            case .securityFailed: .connectionErrorSecurityFailed
            case .certificateRejected: .connectionErrorCertificateRejected
            case .authentication: .connectionErrorAuthentication
            case .accountRestricted: .connectionErrorAccountRestricted
            case .passwordExpired: .connectionErrorPasswordExpired
            case .other: .connectionErrorOther
            }
        let message = Localization.text(key, ["host": host])
        return name.isEmpty ? message : Localization.text(.connectionErrorDetails, ["message": message, "code": name])
    }
}
