import AppKit
import IOSurface
import SwiftUI
import VibeRDPCore

/// Content of the main window: the saved connections and the session they start
/// The session shows in a window of its own, so this window keeps its size and place whatever the session does
/// Questions while connecting come over this window, the reasons a session ended show in its status line
@MainActor
final class ConnectionViewController: NSViewController {
    let model: ConnectionsModel

    private let trusted: TrustedCertificates
    private let keyboard: KeyboardSettingsStore
    private let sessionSettings: SessionSettings
    /// The name the session window keeps its frame under, nil for none
    private let sessionFrameName: String?
    private var session: SessionController?
    /// Keeps the Mac clipboard and the remote one in step while the session lasts
    private var clipboard: ClipboardBridge?
    /// The window of the session, from the start of a connection; it shows once the user is in
    private var sessionWindow: SessionWindowController?
    /// The windows of the host as windows of the Mac, in the Seam mode
    private var seamWindows: SeamWindows?
    /// The state of the Seam link, and whether the user asked for the desktop in place of the windows
    private var seamState = SeamLink.State.closed
    private var prefersDesktop = false
    /// The programs of the host in the Dock while their windows show
    private var dockProxies: DockProxies?
    /// The Start menu of the host in the menu bar, and the programs of the current session
    var startMenu: StartMenu?
    private var remoteApps = RemoteApps()
    /// The server refused RemoteApp: when this session ends, the same attempt starts again without it
    private var retryWithoutRemoteApp: LoginAttempt?
    /// The session runs without RemoteApp because the server refused it: the diagnosis says so
    private var remoteAppRefused = false
    private var desktop: DesktopView? { sessionWindow?.desktop }
    private var wakeObserver: NSObjectProtocol?
    /// The profile of the running session and how it signs in
    private var attempt: LoginAttempt?
    private var host = ""
    /// Why the session ended: the error comes right before Disconnected, and Disconnected shows it
    private var failure: (kind: VRCErrorKind, message: String)?
    /// The first update after each change of size is logged, the rest are too many to read
    private var frameUpdateLogged = false
    /// The windows of the host while the Seam link is ready; the window manager of the Seam mode shows them
    private var remoteWindows = RemoteWindows()

    init(
        trusted: TrustedCertificates, keyboard: KeyboardSettingsStore, profiles: ProfileStore, sessionFrameName: String?,
        sessionSettings: SessionSettings = SessionSettings()
    ) {
        self.trusted = trusted
        self.keyboard = keyboard
        self.sessionSettings = sessionSettings
        self.sessionFrameName = sessionFrameName
        model = ConnectionsModel(store: profiles)
        super.init(nibName: nil, bundle: nil)
        model.newConnectionMode = { [sessionSettings] in sessionSettings.newConnectionMode }
        model.onConnect = { [weak self] id in self?.connect(id) }
        model.onDisconnect = { [weak self] in self?.session?.disconnect() }
        model.onImportWindowsApp = { [weak self] in self?.importWindowsAppConnections(nil) }
        model.windowsAppInstalled = WindowsAppStore.isInstalled
        // After a sleep the connection may be long dead: asking for the desktop shows it at once
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view controller is built in code")
    }

    override func loadView() {
        let connections = NSHostingView(rootView: ConnectionsView(model: model))
        // The toolbar and the search of the SwiftUI view become the toolbar of the AppKit window
        connections.sceneBridgingOptions = [.toolbars]
        connections.frame = NSRect(origin: .zero, size: MainWindow.defaultSize)
        view = connections
    }

    /// The menu command while this window is key; the session window takes it while it is
    @objc func disconnect(_ sender: Any?) {
        session?.disconnect()
    }

    /// The menu command: what the channel of the helper says, in the words of the user, and what to do
    @objc func explainWindows(_ sender: Any?) {
        let diagnosis = SeamDiagnosis.of(seamState)
        let alert = NSAlert()
        alert.messageText = Localization.text(diagnosis.title.key, diagnosis.title.values)
        alert.informativeText = diagnosis.advice(remoteAppRefused: remoteAppRefused)
            .map { Localization.text($0.key, $0.values) }
            .joined(separator: "\n\n")
        alert.alertStyle = { if case .working = diagnosis { .informational } else { .warning } }()
        Diagnostics.info("seam", "diagnosis shown: \(diagnosis)")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The menu command: the desktop in place of the windows of Windows and back, without reconnecting
    @objc func toggleWindowsDesktop(_ sender: Any?) {
        prefersDesktop.toggle()
        applySeamMode()
    }

    /// The menu command: .rdp files chosen in an open panel join the list without connecting
    @objc func importConnectionFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rdpFile]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            let urls = panel.urls
            MainActor.assumeIsolated {
                if response == .OK {
                    self?.importFiles(urls, connecting: false)
                }
            }
        }
    }

    /// The menu command: the connections of Windows App join the list, without their passwords
    /// Reading its store may bring the question of macOS about the data of other apps: it comes only on this command
    @objc func importWindowsAppConnections(_ sender: Any?) {
        importWindowsApp(from: WindowsAppStore())
    }

    func importWindowsApp(from store: WindowsAppStore) {
        let profiles: [ConnectionProfile]
        do {
            profiles = try store.profiles()
        } catch WindowsAppStore.ReadError.unknownSchema {
            showImportProblem(.connectionsWindowsAppUnknown)
            return
        } catch {
            showImportProblem(.connectionsWindowsAppUnreadable)
            return
        }
        guard !profiles.isEmpty else {
            showImportProblem(.connectionsWindowsAppEmpty)
            return
        }
        let count = model.importProfiles(profiles)
        model.status = Localization.text(
            .connectionsWindowsAppImported, ["added": String(count.added), "existing": String(count.existing)])
    }

    /// An import that brought nothing: the status line shows only with a selected profile, so the answer is a sheet
    private func showImportProblem(_ key: TextKey) {
        let alert = NSAlert()
        alert.messageText = Localization.text(key)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// .rdp files opened from the Finder: one file connects at once, as a double click in the Finder means
    func open(_ urls: [URL]) {
        importFiles(urls, connecting: urls.count == 1)
    }

    /// Adds the profiles the files describe; the status names the last file and what became of it
    func importFiles(_ urls: [URL], connecting: Bool) {
        var imported: ConnectionProfile?
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url), let profile = RdpFile(data: data)?.profile(named: name) else {
                model.status = Localization.text(.connectionsImportFailed, ["file": url.lastPathComponent])
                imported = nil
                continue
            }
            let added = model.importProfile(profile)
            imported = model.selectedProfile
            model.status = Localization.text(
                added ? .connectionsImported : .connectionsImportedExisting, ["name": imported?.title ?? name])
        }
        if connecting, let imported, session == nil {
            connect(imported.id)
        }
    }

    /// Connects with the saved profile: the password typed in the editor, else the saved one, else none
    func connect(_ id: UUID) {
        guard session == nil, let profile = model.store.profile(id) else { return }
        let typed = model.password
        let passwords = model.store.passwords
        let saved = typed.isEmpty ? passwords.password(for: id, kind: .server) : nil
        let ownGateway = profile.gateway != nil && !profile.gatewayUsesServerCredentials
        let savedGateway = ownGateway ? passwords.password(for: id, kind: .gateway) : nil
        start(LoginAttempt.first(for: profile, typed: typed, saved: saved, savedGateway: savedGateway))
    }

    /// remoteApp false keeps RemoteApp off even when the profile asks for it: the server refused it before
    private func start(_ attempt: LoginAttempt, remoteApp: Bool = true) {
        guard let profile = model.store.profile(attempt.profileID) else { return }
        guard let address = ServerAddress(profile.address) else {
            model.status = Localization.text(.connectionStatusInvalidHost)
            return
        }
        guard profile.hasValidGateway else {
            model.status = Localization.text(.connectionStatusInvalidGateway)
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
        desktop.scrollSpeed = { [sessionSettings] in sessionSettings.scrollSpeed }
        desktop.keyboard = ProfileKeyboardSettings(store: keyboard, keyboard: profile.keyboard)
        let makeDesktop = { [keyboard, sessionSettings] in
            let other = DesktopView(renderer: renderer)
            other.input = controller
            other.scrollSpeed = { sessionSettings.scrollSpeed }
            other.keyboard = ProfileKeyboardSettings(store: keyboard, keyboard: profile.keyboard)
            return other
        }
        let window = SessionWindowController(
            desktop: desktop, title: profile.title, mode: profile.displayMode, fixedSize: profile.fixedSize,
            sharp: profile.sharpOnRetina, screen: view.window?.screen, frameName: sessionFrameName,
            allScreens: profile.allScreens, makeDesktop: makeDesktop,
            onDisconnect: { [weak controller] in controller?.disconnect() },
            onResize: { [weak controller] desktop in controller?.resizeDesktop(to: desktop) })
        sessionWindow = window
        if window.seamGeometry != nil {
            dockProxies = DockProxies(
                onActivate: { [weak self] ids in self?.programChosen(ids) },
                onQuit: { [weak controller] ids in ids.forEach { controller?.sendSeam(.close, window: $0) } })
        }
        seamWindows = window.seamGeometry.map { geometry in
            SeamWindows(
                geometry: geometry, makeDesktop: makeDesktop,
                onDisconnect: { [weak controller] in controller?.disconnect() },
                onMove: { [weak controller] id, rect in controller?.sendSeam(.move(rect), window: id) },
                onActivate: { [weak controller] id in controller?.sendSeam(.activate, window: id) },
                onMinimize: { [weak controller] id in controller?.sendSeam(.minimize, window: id) })
        }
        model.isBusy = true
        model.activeProfile = attempt.profileID
        let gateway = profile.gateway.map {
            GatewayParameters(
                address: $0, usesServerCredentials: profile.gatewayUsesServerCredentials,
                bypassLocal: profile.gatewayBypassLocal, username: attempt.gatewayUsername,
                password: attempt.gatewayPassword ?? "")
        }
        let started = controller.connect(
            to: address, username: attempt.username, password: attempt.password ?? "", gateway: gateway,
            desktop: window.desktopRequest, audio: profile.audio.mode,
            microphone: profile.microphone, sharedFolder: profile.sharedFolder,
            showsWindows: seamWindows != nil,
            remoteApp: remoteApp && seamWindows != nil && profile.remoteApp)
        if !started {
            session = nil
            sessionWindow = nil
            self.attempt = nil
            model.isBusy = false
            model.activeProfile = nil
            model.status = Localization.text(.connectionStatusStartFailed, ["host": host])
            return
        }
        // The core keeps the offer until the clipboard channel starts
        let bridge = ClipboardBridge(channel: controller, interval: sessionSettings.clipboardInterval)
        bridge.start()
        clipboard = bridge
    }

    private func handle(_ event: SessionController.Event) {
        log(event)
        switch event {
        case .state(.connecting):
            model.status = Localization.text(.connectionStatusConnecting, ["host": host])
        case .state(.connected) where sessionWindow?.isReconnecting == true:
            model.status = Localization.text(.connectionStatusConnected, ["host": host])
            sessionWindow?.hideReconnecting()
        case .state(.connected):
            model.status = Localization.text(.connectionStatusConnected, ["host": host])
            signedIn()
            sessionWindow?.show()
        case .state(.reconnecting):
            model.status = Localization.text(.connectionStatusReconnecting, ["host": host])
            sessionWindow?.showReconnecting(host: host)
        case .reconnecting(let attempt, let maxAttempts):
            sessionWindow?.showReconnectingAttempt(attempt, of: maxAttempts)
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
        case .gatewayMessage(let message):
            show(message)
        case .frameResized:
            sessionWindow?.setSurface(session?.frameSurface())
            seamWindows?.setSurface(session?.frameSurface())
        case .frameUpdated:
            sessionWindow?.frameChanged()
            seamWindows?.frameChanged()
        case .pointer(let pointer):
            sessionWindow?.setPointer(pointer)
            seamWindows?.setPointer(pointer)
        case .remoteClipboard(let formats):
            clipboard?.remoteClipboardChanged(formats)
        case .clipboardDataRequested(let format):
            clipboard?.dataRequested(format)
        case .seam(let state):
            seamChanged(state)
        // RemoteApp comes back as a new connection: the desktop of the refusal lacks the graphics pipeline
        case .remoteAppRefused:
            retryWithoutRemoteApp = attempt
            session?.disconnect()
        case .seamMessage(let message):
            if remoteApps.apply(message) {
                startMenu?.show(seamWindows?.isActive == true ? remoteApps : nil)
            } else if let change = track(message) {
                seamWindows?.apply(change, remoteWindows)
                if seamWindows?.isActive == true {
                    dockProxies?.update(DockGroup.groups(of: remoteWindows))
                }
            }
        }
    }

    /// A program chosen in the Dock or in Cmd-Tab: its minimized windows come back on the host,
    /// the others come forward on the Mac at once
    private func programChosen(_ ids: [UInt64]) {
        for id in ids where remoteWindows.windows[id]?.state == .minimized {
            session?.sendSeam(.restore, window: id)
        }
        seamWindows?.bringForward(ids)
    }

    /// Anything but a ready link has no windows: a new link sends them all again after its hello
    private func seamChanged(_ state: SeamLink.State) {
        seamState = state
        if case .ready = state {} else {
            remoteWindows = RemoteWindows()
            remoteApps = RemoteApps()
        }
        applySeamMode()
    }

    /// A ready link of a helper that reports windows shows them in place of the desktop, unless the user asked
    /// for the desktop; anything else gives the desktop back
    /// The windows stay tracked while the desktop shows, so the switch back needs no word from the helper
    private func applySeamMode() {
        guard let seamWindows else { return }
        var showsWindows = false
        if case .ready(_, let capabilities) = seamState, capabilities.contains("windows") {
            showsWindows = !prefersDesktop
        }
        if showsWindows && !seamWindows.isActive {
            sessionWindow?.setDesktopHidden(true)
            seamWindows.activate(remoteWindows)
            dockProxies?.update(DockGroup.groups(of: remoteWindows))
            showStartMenu()
        } else if !showsWindows && seamWindows.isActive {
            seamWindows.deactivate()
            dockProxies?.stopAll()
            startMenu?.show(nil)
            sessionWindow?.setDesktopHidden(false)
        }
    }

    /// The Start menu of a helper that has one: asked for once a link, shown while the windows show
    private func showStartMenu() {
        guard case .ready(_, let capabilities) = seamState, capabilities.contains("launcher") else { return }
        startMenu?.onLaunch = { [weak session] id in session?.launchApp(id) }
        startMenu?.show(remoteApps)
        if remoteApps.apps.isEmpty {
            session?.requestApps()
        }
    }

    /// The windows of the host, and in the log what changed: ids and executables, never titles or icons
    @discardableResult
    private func track(_ message: MessagePackValue) -> RemoteWindows.Change? {
        let outcome = remoteWindows.apply(message)
        if let note = outcome.note {
            Diagnostics.info("seam", note)
        }
        switch outcome.change {
        case .created(let id):
            let exe = remoteWindows.windows[id]?.exe ?? ""
            Diagnostics.info("seam", "window \(id) \(exe) created, \(remoteWindows.windows.count) in all")
        case .destroyed(let id):
            Diagnostics.info("seam", "window \(id) destroyed, \(remoteWindows.windows.count) in all")
        case .updated, .icon, .order, .focus, nil:
            break
        }
        return outcome.change
    }

    /// The session in the diagnostics log: its states and errors, and the frame at each change of size with its first
    /// update, so a desktop that stays empty shows where the frames stop; pixels and input are never logged
    private func log(_ event: SessionController.Event) {
        switch event {
        case .state(let state):
            Diagnostics.info("session", "state \(state.rawValue)")
        case .failed(let kind, let name):
            Diagnostics.warning("session", "failed: kind \(kind.rawValue), \(name)")
        case .reconnecting(let attempt, let maxAttempts):
            Diagnostics.info("session", "reconnecting, attempt \(attempt) of \(maxAttempts)")
        case .frameResized(let width, let height):
            let surface = session?.frameSurface().map { "\(IOSurfaceGetWidth($0))x\(IOSurfaceGetHeight($0))" }
            Diagnostics.info("frame", "resized to \(width)x\(height), surface \(surface ?? "missing")")
            frameUpdateLogged = false
        case .frameUpdated where !frameUpdateLogged:
            Diagnostics.info(
                "frame", "first update since the resize, desktop view \(desktop == nil ? "missing" : "present")")
            frameUpdateLogged = true
        case .seam(let state):
            Diagnostics.info("seam", "state \(state)")
        default:
            break
        }
    }

    /// The server let the user in: the name that worked stays in the profile, a typed password worth keeping
    /// goes to the Keychain
    private func signedIn() {
        guard let attempt, var profile = model.store.profile(attempt.profileID) else { return }
        profile.username = attempt.username
        profile.lastConnected = Date()
        if !profile.gatewayUsesServerCredentials {
            profile.gatewayUsername = attempt.gatewayUsername
        }
        model.store.update(profile)
        model.password = ""
        let saved: [(PasswordKind, String?)] = [
            (.server, attempt.passwordToSave), (.gateway, attempt.gatewayPasswordToSave),
        ]
        for case (let kind, let password?) in saved {
            let status = model.store.passwords.setPassword(
                password, for: profile.id, kind: kind, label: Self.label(for: profile, kind: kind))
            if status != errSecSuccess {
                tell(Localization.text(.connectionPasswordNotSaved, ["code": String(status)]))
            }
        }
        model.refreshSavedPassword()
    }

    private func sessionEnded() {
        closeSheet()
        // The desktop keeps its last frame after the engine lets go of it: that frame becomes the picture of the tile
        if let id = attempt?.profileID, let surface = sessionWindow?.desktop.surface {
            model.keepSnapshot(surface, for: id)
        }
        model.activeProfile = nil
        let wasShown = sessionWindow?.window?.isVisible == true
        seamWindows?.deactivate()
        seamWindows = nil
        dockProxies?.invalidate()
        dockProxies = nil
        startMenu?.show(nil)
        startMenu?.onLaunch = nil
        remoteApps = RemoteApps()
        seamState = .closed
        prefersDesktop = false
        remoteAppRefused = false
        sessionWindow?.end()
        sessionWindow = nil
        // The list comes forward with the reason the session ended in its status line
        if wasShown {
            view.window?.makeKeyAndOrderFront(nil)
        }
        clipboard?.stop()
        clipboard = nil
        session = nil
        model.isBusy = false
        let ended = attempt
        attempt = nil
        if let retry = retryWithoutRemoteApp {
            retryWithoutRemoteApp = nil
            failure = nil
            Diagnostics.info("rail", "connecting again without RemoteApp")
            start(retry, remoteApp: false)
            remoteAppRefused = true
            return
        }
        model.status = failure?.message ?? Localization.text(.connectionStatusDisconnected, ["host": host])
        guard let ended, let failure, let profile = model.store.profile(ended.profileID) else { return }
        // A wrong password is asked for again, and the answer starts a new connection
        // A gateway turns a wrong password down as access denied, which for it asks for the gateway password again
        if failure.kind == .authentication {
            askAgain(after: ended, gateway: false)
        } else if failure.kind == .accountRestricted, let gateway = profile.gateway {
            model.status = Localization.text(.connectionErrorGatewayDenied, ["gateway": gateway.host])
            askAgain(after: ended, gateway: !profile.gatewayUsesServerCredentials)
        }
    }

    /// Questions come over the window the user looks at: the session window once it shows, the list before
    private var questionWindow: NSWindow? {
        if let window = sessionWindow?.window, window.isVisible {
            return window
        }
        return view.window
    }

    private func ask(about certificate: ServerCertificate, verdict: CertificateVerdict) {
        guard let window = questionWindow else {
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
    /// A gateway that takes the credentials of the computer asks for those, so the question is about the computer
    private func askForCredentials(_ request: CredentialsRequest) {
        guard let window = questionWindow, let attempt, let profile = model.store.profile(attempt.profileID) else {
            session?.cancelCredentials()
            return
        }
        let ownGateway = request.target == .gateway && !profile.gatewayUsesServerCredentials
        let known = ownGateway ? attempt.gatewayUsername : attempt.username
        let prompt = CredentialsPrompt(
            target: ownGateway ? .gateway : .server, host: ownGateway ? profile.gateway?.host ?? host : host,
            username: request.username ?? known, remember: attempt.remember, retry: false)
        let session = self.session
        prompt.alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, let session, session === self.session else { return }
                guard let answer = prompt.answer(for: response) else {
                    session.cancelCredentials()
                    return
                }
                if ownGateway {
                    self.attempt?.answeredGateway(
                        username: answer.username, password: answer.password, remember: answer.remember)
                } else {
                    self.attempt?.answered(
                        username: answer.username, password: answer.password, remember: answer.remember)
                }
                self.applyRemember(answer.remember)
                session.answerCredentials(username: answer.username, password: answer.password)
            }
        }
    }

    /// After a wrong password: the same profile, the name and password the user enters now,
    /// for the computer or for a gateway with credentials of its own
    private func askAgain(after ended: LoginAttempt, gateway: Bool) {
        guard let window = view.window, let profile = model.store.profile(ended.profileID) else { return }
        let prompt = CredentialsPrompt(
            target: gateway ? .gateway : .server, host: gateway ? profile.gateway?.host ?? host : host,
            username: gateway ? ended.gatewayUsername : ended.username, remember: ended.remember, retry: true)
        prompt.alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.session == nil, let answer = prompt.answer(for: response) else { return }
                var next = ended
                if gateway {
                    next.answeredGateway(
                        username: answer.username, password: answer.password, remember: answer.remember)
                } else {
                    next.answered(username: answer.username, password: answer.password, remember: answer.remember)
                }
                self.attempt = next
                self.applyRemember(answer.remember)
                self.start(next)
            }
        }
    }

    /// A gateway message: a consent waits for the user's answer, a notice only needs to be read
    private func show(_ message: GatewayMessage) {
        guard let window = questionWindow else {
            if message.needsConsent {
                session?.answerGatewayMessage(accept: false)
            }
            return
        }
        let gateway = attempt.flatMap { model.store.profile($0.profileID)?.gateway?.host } ?? host
        let alert = NSAlert()
        alert.messageText = Localization.text(.gatewayMessageTitle, ["gateway": gateway])
        alert.informativeText = message.text
        if message.needsConsent {
            alert.addButton(withTitle: Localization.text(.gatewayMessageAccept))
            alert.addButton(withTitle: Localization.text(.gatewayMessageDecline))
        } else {
            alert.addButton(withTitle: Localization.text(.gatewayMessageClose))
        }
        let session = self.session
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard message.needsConsent, let self, let session, session === self.session else { return }
                session.answerGatewayMessage(accept: response == .alertFirstButtonReturn)
            }
        }
    }

    /// Unticking the box in a question forgets the saved passwords at once, as in the editor
    private func applyRemember(_ remember: Bool) {
        guard let id = attempt?.profileID, var profile = model.store.profile(id) else { return }
        profile.remembersPassword = remember
        model.store.update(profile)
        if !remember {
            for kind in PasswordKind.allCases {
                model.store.passwords.deletePassword(for: id, kind: kind)
            }
            model.refreshSavedPassword()
        }
    }

    /// A notice that needs no answer, over whatever the window shows
    private func tell(_ text: String) {
        guard let window = questionWindow else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    /// The session ended while a question was open: the question has nothing left to answer
    private func closeSheet() {
        for window in [view.window, sessionWindow?.window].compactMap({ $0 }) {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .abort)
            }
        }
    }

    /// What Keychain Access shows for a saved password
    static func label(for profile: ConnectionProfile, kind: PasswordKind) -> String {
        let key: TextKey =
            switch kind {
            case .server: .connectionPasswordLabelInKeychain
            case .gateway: .connectionGatewayPasswordLabelInKeychain
            }
        return Localization.text(key, ["connection": profile.title])
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
    /// Disconnecting makes sense only while a session exists, from connecting until Disconnected,
    /// and the import from Windows App only where it is installed
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(disconnect(_:)): session != nil
        case #selector(explainWindows(_:)): seamWindows != nil
        case #selector(toggleWindowsDesktop(_:)):
            {
                menuItem.state = prefersDesktop ? .on : .off
                return seamWindows != nil
            }()
        case #selector(importWindowsAppConnections(_:)): model.windowsAppInstalled
        default: true
        }
    }
}
