import AppKit
import SwiftUI
import VibeRDPCore

/// Content of the main window: the saved connections, and the remote desktop over them while connected
@MainActor
final class ConnectionViewController: NSViewController {
    let model: ConnectionsModel

    private let trusted: TrustedCertificates
    private let keyboard: KeyboardSettingsStore
    private var session: SessionController?
    private var connections: NSView?
    private var desktop: DesktopView?
    /// The profile of the running session and how it signs in
    private var attempt: LoginAttempt?
    private var host = ""
    /// Why the session ended: the error comes right before Disconnected, and Disconnected shows it
    private var failure: (kind: VRCErrorKind, message: String)?

    init(trusted: TrustedCertificates, keyboard: KeyboardSettingsStore, profiles: ProfileStore) {
        self.trusted = trusted
        self.keyboard = keyboard
        model = ConnectionsModel(store: profiles)
        super.init(nibName: nil, bundle: nil)
        model.onConnect = { [weak self] id in self?.connect(id) }
        model.onDisconnect = { [weak self] in self?.session?.disconnect() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view controller is built in code")
    }

    override func loadView() {
        let connections = NSHostingView(rootView: ConnectionsView(model: model))
        connections.frame = NSRect(origin: .zero, size: MainWindow.defaultSize)
        connections.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: MainWindow.defaultSize))
        container.addSubview(connections)
        self.connections = connections
        view = container
    }

    /// The menu command: while connected, the desktop covers the list together with its button
    @objc func disconnect(_ sender: Any?) {
        session?.disconnect()
    }

    /// Connects with the saved profile: the password typed in the editor, else the saved one, else none
    func connect(_ id: UUID) {
        guard session == nil, let profile = model.store.profile(id) else { return }
        let typed = model.password
        let saved = typed.isEmpty ? model.store.passwords.password(for: id) : nil
        start(LoginAttempt.first(for: profile, typed: typed, saved: saved))
    }

    private func start(_ attempt: LoginAttempt) {
        guard let profile = model.store.profile(attempt.profileID) else { return }
        guard let address = ServerAddress(profile.address) else {
            model.status = Localization.text(.connectionStatusInvalidHost)
            return
        }
        guard let renderer = FrameRenderer() else {
            model.status = Localization.text(.connectionStatusNoMetal)
            return
        }

        let controller = SessionController(trusted: trusted) { [weak self] event in
            self?.handle(event)
        }
        host = address.host
        failure = nil
        self.attempt = attempt
        session = controller
        let desktop = DesktopView(renderer: renderer)
        desktop.input = controller
        desktop.keyboard = ProfileKeyboardSettings(store: keyboard, keyboard: profile.keyboard)
        self.desktop = desktop
        model.isBusy = true
        // The desktop is as large as the window in points; scaling it to the pixels of the display is task 3.2
        let size = view.bounds.size
        let started = controller.connect(
            to: address, username: attempt.username, password: attempt.password ?? "",
            desktop: CGSize(width: size.width.rounded(), height: size.height.rounded()))
        if !started {
            session = nil
            self.desktop = nil
            self.attempt = nil
            model.isBusy = false
            model.status = Localization.text(.connectionStatusStartFailed, ["host": host])
        }
    }

    private func handle(_ event: SessionController.Event) {
        switch event {
        case .state(.connecting):
            model.status = Localization.text(.connectionStatusConnecting, ["host": host])
        case .state(.connected):
            model.status = Localization.text(.connectionStatusConnected, ["host": host])
            signedIn()
            showDesktop()
        case .state(.disconnected):
            sessionEnded()
        case .state:
            break
        case .failed(let kind, let name):
            failure = (kind, Self.message(for: kind, name: name, host: host))
        case .certificateQuestion(let certificate, let verdict):
            ask(about: certificate, verdict: verdict)
        case .credentialsQuestion(let request):
            askForCredentials(request)
        case .frameResized:
            desktop?.surface = session?.frameSurface()
        case .frameUpdated:
            desktop?.frameChanged()
        case .pointer(let pointer):
            desktop?.pointer = pointer
        }
    }

    /// The server let the user in: the name that worked stays in the profile, a typed password worth keeping
    /// goes to the Keychain
    private func signedIn() {
        guard let attempt, var profile = model.store.profile(attempt.profileID) else { return }
        profile.username = attempt.username
        model.store.update(profile)
        model.password = ""
        if let password = attempt.passwordToSave {
            let status = model.store.passwords.setPassword(password, for: profile.id, label: Self.label(for: profile))
            if status != errSecSuccess {
                tell(Localization.text(.connectionPasswordNotSaved, ["code": String(status)]))
            }
        }
        model.refreshSavedPassword()
    }

    private func sessionEnded() {
        closeSheet()
        hideDesktop()
        session = nil
        model.isBusy = false
        let ended = attempt
        attempt = nil
        model.status = failure?.message ?? Localization.text(.connectionStatusDisconnected, ["host": host])
        // A wrong password is asked for again, and the answer starts a new connection
        if failure?.kind == .authentication, let ended {
            askAgain(after: ended)
        }
    }

    /// The desktop covers the list while connected; the list stays underneath for the next connection
    private func showDesktop() {
        guard let desktop, desktop.superview == nil else { return }
        desktop.frame = view.bounds
        desktop.autoresizingMask = [.width, .height]
        view.addSubview(desktop)
        connections?.isHidden = true
        if let profile = attempt.flatMap({ model.store.profile($0.profileID) }) {
            view.window?.subtitle = profile.title
        }
        view.window?.makeFirstResponder(desktop)
    }

    private func hideDesktop() {
        desktop?.removeFromSuperview()
        desktop = nil
        connections?.isHidden = false
        view.window?.subtitle = ""
        view.window?.makeFirstResponder(connections)
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

    /// The engine waits for credentials it was not given; declining ends the connection without an error
    private func askForCredentials(_ request: CredentialsRequest) {
        guard let window = view.window, let attempt else {
            session?.cancelCredentials()
            return
        }
        let prompt = CredentialsPrompt(
            target: request.target, host: host, username: request.username ?? attempt.username,
            remember: attempt.remember, retry: false)
        let session = self.session
        prompt.alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, let session, session === self.session else { return }
                guard let answer = prompt.answer(for: response) else {
                    session.cancelCredentials()
                    return
                }
                if request.target == .server {
                    self.attempt?.answered(
                        username: answer.username, password: answer.password, remember: answer.remember)
                    self.applyRemember(answer.remember)
                }
                session.answerCredentials(username: answer.username, password: answer.password)
            }
        }
    }

    /// After a wrong password: the same profile, the name and password the user enters now
    private func askAgain(after ended: LoginAttempt) {
        guard let window = view.window else { return }
        let prompt = CredentialsPrompt(
            target: .server, host: host, username: ended.username, remember: ended.remember, retry: true)
        prompt.alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.session == nil, let answer = prompt.answer(for: response) else { return }
                var next = ended
                next.answered(username: answer.username, password: answer.password, remember: answer.remember)
                self.attempt = next
                self.applyRemember(answer.remember)
                self.start(next)
            }
        }
    }

    /// Unticking the box in a question forgets the saved password at once, as in the editor
    private func applyRemember(_ remember: Bool) {
        guard let id = attempt?.profileID, var profile = model.store.profile(id) else { return }
        profile.remembersPassword = remember
        model.store.update(profile)
        if !remember {
            model.store.passwords.deletePassword(for: id)
            model.refreshSavedPassword()
        }
    }

    /// A notice that needs no answer, over whatever the window shows
    private func tell(_ text: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    /// The session ended while a question was open: the question has nothing left to answer
    private func closeSheet() {
        if let window = view.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .abort)
        }
    }

    /// What Keychain Access shows for the saved password
    static func label(for profile: ConnectionProfile) -> String {
        Localization.text(.connectionPasswordLabelInKeychain, ["connection": profile.title])
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

extension ConnectionViewController: NSMenuItemValidation {
    /// Disconnecting makes sense only while a session exists, from connecting until Disconnected
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(disconnect(_:)) || session != nil
    }
}
