import Foundation
import IOSurface
import ImageIO
import VibeRDPCore

/// One connection attempt to one server: wraps a VRCSession and brings its callbacks to the main thread
/// The core connects a session once, so a new attempt takes a new controller
@MainActor
final class SessionController {
    enum Event: Equatable {
        case state(VRCSessionState)
        case failed(VRCErrorKind, name: String)
        /// The certificate needs the user; answer with answerCertificate
        case certificateQuestion(ServerCertificate, CertificateVerdict)
        /// The engine lacks a user name or a password; answer with answerCredentials or cancelCredentials
        case credentialsQuestion(CredentialsRequest)
        /// The gateway has a message; one that needs consent waits for answerGatewayMessage
        case gatewayMessage(GatewayMessage)
        /// While the connection is being restored: this attempt of the most there will be
        case reconnecting(attempt: UInt32, of: UInt32)
        /// The desktop got a new surface of this size in pixels: take it with frameSurface
        case frameResized(width: UInt32, height: UInt32)
        /// Pixels of the current surface changed
        case frameUpdated
        /// The server changed its pointer
        case pointer(RemotePointer)
        /// The clipboard of the remote computer offers these formats now, none when it holds nothing the Mac takes
        case remoteClipboard([VRCClipboardFormat])
        /// Something on the remote computer pastes the Mac clipboard: answer with provideClipboardData
        case clipboardDataRequested(VRCClipboardFormat)
        /// The Seam channel of the helper on Windows changed state
        case seam(SeamLink.State)
        /// A message of the helper beyond the greeting and the pings: windows, icons, answers to commands
        case seamMessage(MessagePackValue)
        /// The server refused RemoteApp: the session is a desktop, and a new one without RemoteApp does better
        case remoteAppRefused
    }

    /// What RemoteApp calls itself where the helper would give its name
    static let remoteAppAgent = "RemoteApp"
    /// RemoteApp reports windows and takes commands for them, as a helper with these capabilities does
    static let remoteAppCapabilities: Set<String> = ["windows", "commands"]

    /// How often the Seam link looks at its clock: the shortest of its intervals, the hello timeout, is 2 seconds
    private static let seamTick: TimeInterval = 0.5

    private let trusted: TrustedCertificates
    private let onEvent: (Event) -> Void
    private var handle: SessionHandle?
    private var pendingCertificate: ServerCertificate?
    /// The link of the Seam channel; connect says whether this client shows the windows of the host
    private var seam = SeamLink(agent: SessionController.seamAgent, capabilities: [])
    private static let seamAgent = "VibeRDP \(AppDelegate.appVersion)"
    /// The capability of a client that shows the windows of the host, section 5 of the specification
    static let showsWindowsCapability = "seam"
    private var seamTimer: Timer?
    /// RemoteApp in the words of the Seam protocol, while the server runs the program
    private var rail = RailBridge()
    private var railActive = false
    /// The language of the Mac layout the helper was last asked for: the same one is not asked for again
    private var sentLanguage: String?
    private var inputObserver: DistributedObservation?

    init(trusted: TrustedCertificates, onEvent: @escaping (Event) -> Void) {
        self.trusted = trusted
        self.onEvent = onEvent
        inputObserver = DistributedObservation(InputLanguage.changed) { [weak self] in self?.syncLayout() }
    }

    /// The layout of Windows follows the Mac: a helper that can switch it is asked when the link comes up
    /// and at every switch on the Mac, decision 52
    private func syncLayout() {
        guard !railActive, case .ready(_, let capabilities) = seam.state, capabilities.contains("keyboard-layout"),
            let language = InputLanguage.current(), language != sentLanguage, let body = seam.layout(language)
        else { return }
        sentLanguage = language
        Diagnostics.info("seam", "layout of Windows asked for \(language)")
        send([body])
    }

    /// Starts connecting with a desktop of the given size in pixels, through the gateway when there is one
    /// Empty credentials are not given at all: the engine asks for them when the server needs them
    /// False when the core refuses the parameters or cannot start
    func connect(
        to address: ServerAddress, username: String, password: String, gateway: GatewayParameters? = nil,
        desktop: DesktopRequest, audio: VRCAudioMode = .off, microphone: Bool = false,
        sharedFolder: String = "", showsWindows: Bool = false, remoteApp: Bool = false
    ) -> Bool {
        guard handle == nil else { return false }
        seam = SeamLink(agent: Self.seamAgent, capabilities: showsWindows ? [Self.showsWindowsCapability] : [])
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self)
        let sink = EventSink(continuation: continuation)
        var callbacks = EventSink.callbacks
        guard let session = VRCSessionCreate(&callbacks, Unmanaged.passUnretained(sink).toOpaque()) else {
            return false
        }
        handle = SessionHandle(session: session, sink: sink)

        Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }

        let strings = CStrings()
        var params = VRCConnectionParams()
        params.host = strings.copy(address.host)
        params.port = address.port ?? 0
        params.width = UInt32(desktop.size.width)
        params.height = UInt32(desktop.size.height)
        params.scale = desktop.scale
        let monitors = desktop.monitors
        let monitorBuffer = UnsafeMutablePointer<VRCMonitor>.allocate(capacity: max(monitors.count, 1))
        defer { monitorBuffer.deallocate() }
        monitorBuffer.initialize(from: monitors, count: monitors.count)
        params.monitors = monitors.count >= 2 ? UnsafePointer(monitorBuffer) : nil
        params.monitorCount = monitors.count >= 2 ? monitors.count : 0
        params.audio = audio
        params.microphone = microphone
        params.sharedFolder = sharedFolder.isEmpty ? nil : strings.copy(sharedFolder)
        params.username = strings.copy(username)
        params.password = strings.copy(password)
        if let gateway {
            params.gatewayHost = strings.copy(gateway.address.host)
            params.gatewayPort = gateway.address.port ?? 0
            params.gatewayUsesServerCredentials = gateway.usesServerCredentials
            params.gatewayBypassLocal = gateway.bypassLocal
            params.gatewayUsername = strings.copy(gateway.username)
            params.gatewayPassword = strings.copy(gateway.password)
        }
        params.remoteApp = remoteApp
        // The engine copies the strings during the call, so they may go right after it
        let result = withExtendedLifetime(strings) { VRCSessionConnect(session, &params) }
        return result == .OK
    }

    func disconnect() {
        if let handle {
            VRCSessionDisconnect(handle.session)
        }
    }

    /// The surface the engine draws the desktop into; nil before the first frameResized
    func frameSurface() -> IOSurfaceRef? {
        handle.flatMap { VRCSessionCopyFrameSurface($0.session) }
    }

    /// The user's answer to the credentials question: DOMAIN\user or user@domain, and the password
    func answerCredentials(username: String, password: String) {
        if let handle {
            _ = VRCSessionProvideCredentials(handle.session, username, nil, password)
        }
    }

    /// The user declined to sign in: the session ends without an error
    func cancelCredentials() {
        if let handle {
            _ = VRCSessionCancelCredentials(handle.session)
        }
    }

    /// The server sends the whole desktop again: after the Mac wakes, a connection that died shows it at once
    func refresh() {
        if let handle {
            _ = VRCSessionRefresh(handle.session)
        }
    }

    /// The desktop follows the window: the server redraws it at this size, and frameResized follows
    func resizeDesktop(to desktop: DesktopRequest) {
        if let handle {
            _ = VRCSessionResizeDesktop(
                handle.session, UInt32(clamping: Int(desktop.size.width)), UInt32(clamping: Int(desktop.size.height)),
                desktop.scale)
        }
    }

    /// The user's answer to a gateway message that needs consent
    func answerGatewayMessage(accept: Bool) {
        if let handle {
            _ = VRCSessionResolveGatewayMessage(handle.session, accept)
        }
    }

    /// The user's answer to the last certificate question
    func answerCertificate(accept: Bool, remember: Bool) {
        guard let certificate = pendingCertificate, let handle else { return }
        pendingCertificate = nil
        if accept && remember {
            trusted.remember(certificate.fingerprint, host: certificate.host, port: certificate.port)
        }
        _ = VRCSessionResolveCertificate(handle.session, accept)
    }

    private func handle(_ event: CoreEvent) {
        switch event {
        case .state(let state):
            if state == .disconnected {
                pendingCertificate = nil
            }
            onEvent(.state(state))
        case .failed(let kind, let name):
            onEvent(.failed(kind, name: name))
        case .frameResized(let width, let height):
            onEvent(.frameResized(width: width, height: height))
        case .frameUpdated:
            onEvent(.frameUpdated)
        case .pointer(let pointer):
            onEvent(.pointer(pointer))
        case .credentials(let request):
            onEvent(.credentialsQuestion(request))
        case .gatewayMessage(let message):
            onEvent(.gatewayMessage(message))
        case .reconnecting(let attempt, let maxAttempts):
            onEvent(.reconnecting(attempt: attempt, of: maxAttempts))
        case .remoteClipboard(let formats):
            onEvent(.remoteClipboard(formats))
        case .clipboardDataRequested(let format):
            onEvent(.clipboardDataRequested(format))
        case .railState(let state, let code):
            railChanged(state, code: code)
        case .railWindow(let order):
            rail.window(order).forEach { onEvent(.seamMessage($0)) }
        case .railWindowDeleted(let id):
            rail.deleted(id).forEach { onEvent(.seamMessage($0)) }
        case .railIcon(let id, let png):
            rail.icon(id, png: png).forEach { onEvent(.seamMessage($0)) }
        case .railDesktop(let active, let order):
            rail.desktop(active: active, order: order).forEach { onEvent(.seamMessage($0)) }
        // Under RemoteApp the windows are the server's: a helper, should one answer too, is not asked
        case .seamOpened where railActive, .seamReceived where railActive, .seamClosed where railActive:
            break
        case .seamOpened:
            send(seam.opened(at: Date()))
            startSeamTimer()
            onEvent(.seam(seam.state))
        case .seamReceived(let body):
            let before = seam.state
            let outcome = seam.received(body, at: Date())
            if let note = outcome.note {
                Diagnostics.info("seam", note)
            }
            if seam.state != before {
                sentLanguage = nil
                syncLayout()
                onEvent(.seam(seam.state))
            }
            if let message = outcome.message {
                onEvent(.seamMessage(message))
            }
        case .seamClosed:
            seamTimer?.invalidate()
            seamTimer = nil
            seam.closed()
            onEvent(.seam(seam.state))
        case .certificate(let host, let port, let pem):
            Task { [weak self] in
                let examined = await Task.detached(priority: .userInitiated) {
                    ServerCertificate(host: host, port: port, pem: pem).map { ($0, CertificateTrust.evaluate($0)) }
                }.value
                self?.certificateExamined(examined)
            }
        }
    }

    /// Asks the helper to act on a window of the host, or RemoteApp when the server runs the program;
    /// nothing goes while neither is ready
    func sendSeam(_ command: SeamLink.Command, window id: UInt64) {
        if railActive {
            sendRail(command, window: id)
        } else if let body = seam.command(command, window: id) {
            send([body])
        }
    }

    private func sendRail(_ command: SeamLink.Command, window id: UInt64) {
        guard let handle, let window = UInt32(exactly: id) else { return }
        let result: VRCResult
        switch command {
        case .activate:
            result = VRCSessionRailActivate(handle.session, window)
        case .move(let visible):
            guard let frame = rail.frame(of: id, visible: visible) else { return }
            result = VRCSessionRailMove(
                handle.session, window, Int32(frame.minX), Int32(frame.minY), UInt32(max(frame.width, 0)),
                UInt32(max(frame.height, 0)))
        case .minimize:
            result = VRCSessionRailSystemCommand(handle.session, window, .minimize)
        case .maximize:
            result = VRCSessionRailSystemCommand(handle.session, window, .maximize)
        case .restore:
            result = VRCSessionRailSystemCommand(handle.session, window, .restore)
        case .close:
            result = VRCSessionRailSystemCommand(handle.session, window, .close)
        }
        if result != .OK {
            Diagnostics.warning("rail", "\(command.action) of window \(id) not sent: \(result.rawValue)")
        }
    }

    /// The program started: the windows come as a ready helper's would; refused, the app starts over without it
    private func railChanged(_ state: VRCRailState, code: UInt32) {
        switch state {
        case .started:
            Diagnostics.info("rail", "the program started")
            railActive = true
            onEvent(.seam(.ready(agent: Self.remoteAppAgent, capabilities: Self.remoteAppCapabilities)))
        case .refused:
            Diagnostics.warning("rail", "RemoteApp refused, code \(code)")
            railActive = false
            onEvent(.remoteAppRefused)
        }
    }

    /// Asks the helper for the programs of the Start menu of the host
    func requestApps() {
        if let body = seam.appsRequest() {
            send([body])
        }
    }

    /// Asks the helper to start a program of the Start menu of the host
    func launchApp(_ id: String) {
        if let body = seam.launch(id) {
            send([body])
        }
    }

    /// Bodies for the helper, each framed by the core
    private func send(_ bodies: [MessagePackValue]) {
        guard let handle else { return }
        for body in bodies {
            let bytes = MessagePack.encode(body)
            let result = bytes.withUnsafeBytes {
                VRCSessionSendSeam(handle.session, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            if result != .OK {
                Diagnostics.warning("seam", "body not sent: \(result.rawValue)")
            }
        }
    }

    private func startSeamTimer() {
        seamTimer?.invalidate()
        seamTimer = Timer.scheduledTimer(withTimeInterval: Self.seamTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.seamTicked() }
        }
    }

    private func seamTicked() {
        let before = seam.state
        send(seam.tick(at: Date()))
        if seam.state != before {
            onEvent(.seam(seam.state))
        }
        switch seam.state {
        case .silent, .lost, .incompatible, .closed:
            seamTimer?.invalidate()
            seamTimer = nil
        case .greeting, .ready:
            break
        }
    }

    private func certificateExamined(_ examined: (ServerCertificate, SystemTrust)?) {
        guard let handle else { return }
        guard let (certificate, system) = examined else {
            _ = VRCSessionResolveCertificate(handle.session, false)
            return
        }

        let remembered = trusted.fingerprint(host: certificate.host, port: certificate.port)
        let verdict = CertificateTrust.verdict(
            system: system, remembered: remembered, fingerprint: certificate.fingerprint)
        if verdict.acceptsWithoutAsking {
            _ = VRCSessionResolveCertificate(handle.session, true)
        } else {
            pendingCertificate = certificate
            onEvent(.certificateQuestion(certificate, verdict))
        }
    }
}

/// Whose credentials the engine asks for, and the user name it already holds
struct CredentialsRequest: Equatable, Sendable {
    let target: VRCCredentialsTarget
    /// DOMAIN\user when the engine has a domain; nil when it has no user name
    let username: String?
}

/// Where the gateway is and whose credentials it takes
struct GatewayParameters: Equatable {
    let address: ServerAddress
    let usesServerCredentials: Bool
    let bypassLocal: Bool
    /// The gateway's own credentials; empty lets the engine ask for them
    let username: String
    let password: String
}

/// What a gateway tells the user: a consent to accept before connecting, or a notice along the way
struct GatewayMessage: Equatable, Sendable {
    let kind: VRCGatewayMessageKind
    let needsConsent: Bool
    let text: String
}

/// What the C callbacks hand over, copied out of memory that is valid only during the call
private enum CoreEvent: Sendable {
    case state(VRCSessionState)
    case failed(VRCErrorKind, name: String)
    case certificate(host: String, port: UInt16, pem: Data)
    case frameResized(width: UInt32, height: UInt32)
    case frameUpdated
    case pointer(RemotePointer)
    case credentials(CredentialsRequest)
    case gatewayMessage(GatewayMessage)
    case reconnecting(attempt: UInt32, of: UInt32)
    case remoteClipboard([VRCClipboardFormat])
    case clipboardDataRequested(VRCClipboardFormat)
    case seamOpened
    case seamReceived(Data)
    case seamClosed
    case railState(VRCRailState, code: UInt32)
    case railWindow(RailBridge.Order)
    case railWindowDeleted(UInt64)
    case railIcon(UInt64, png: Data)
    case railDesktop(active: UInt64?, order: [UInt64]?)
}

/// The userData of the session: the callbacks run on the session thread and only enqueue, never block
private final class EventSink: Sendable {
    let continuation: AsyncStream<CoreEvent>.Continuation

    init(continuation: AsyncStream<CoreEvent>.Continuation) {
        self.continuation = continuation
    }

    static var callbacks: VRCCallbacks {
        VRCCallbacks(
            stateChanged: { userData, state in
                eventSink(userData).continuation.yield(.state(state))
            },
            error: { userData, kind, _, name, _ in
                eventSink(userData).continuation.yield(.failed(kind, name: name.map { String(cString: $0) } ?? ""))
            },
            verifyCertificate: { userData, request in
                guard let request = request?.pointee, let host = request.host, let pem = request.pem else { return }
                let chain = Data(bytes: pem, count: request.pemLength)
                let event = CoreEvent.certificate(host: String(cString: host), port: request.port, pem: chain)
                eventSink(userData).continuation.yield(event)
            },
            frameResized: { userData, width, height in
                eventSink(userData).continuation.yield(.frameResized(width: width, height: height))
            },
            // The view redraws the whole desktop from the surface, so the rectangle is not carried over
            frameUpdated: { userData, _, _, _, _ in
                eventSink(userData).continuation.yield(.frameUpdated)
            },
            pointerChanged: { userData, kind, image in
                eventSink(userData).continuation.yield(.pointer(remotePointer(kind, image)))
            },
            credentialsNeeded: { userData, request in
                guard let request = request?.pointee else { return }
                let username = request.username.map { String(cString: $0) }
                eventSink(userData).continuation.yield(
                    .credentials(CredentialsRequest(target: request.target, username: username)))
            },
            gatewayMessage: { userData, message in
                guard let message = message?.pointee else { return }
                let text = message.text.map { String(cString: $0) } ?? ""
                eventSink(userData).continuation.yield(
                    .gatewayMessage(
                        GatewayMessage(kind: message.kind, needsConsent: message.needsConsent, text: text)))
            },
            reconnecting: { userData, attempt, maxAttempts in
                eventSink(userData).continuation.yield(.reconnecting(attempt: attempt, of: maxAttempts))
            },
            remoteClipboardChanged: { userData, formats, count in
                let offered = formats.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
                eventSink(userData).continuation.yield(.remoteClipboard(offered))
            },
            clipboardDataRequested: { userData, format in
                eventSink(userData).continuation.yield(.clipboardDataRequested(format))
            },
            seamOpened: { userData in
                eventSink(userData).continuation.yield(.seamOpened)
            },
            seamReceived: { userData, body, length in
                let copy = body.map { Data(bytes: $0, count: length) } ?? Data()
                eventSink(userData).continuation.yield(.seamReceived(copy))
            },
            seamClosed: { userData in
                eventSink(userData).continuation.yield(.seamClosed)
            },
            railState: { userData, state, code in
                eventSink(userData).continuation.yield(.railState(state, code: code))
            },
            railWindow: { userData, window in
                guard let window = window?.pointee else { return }
                eventSink(userData).continuation.yield(.railWindow(railOrder(window)))
            },
            railWindowDeleted: { userData, id in
                eventSink(userData).continuation.yield(.railWindowDeleted(UInt64(id)))
            },
            railIcon: { userData, id, pixels, width, height in
                guard let pixels, let png = pngOfBGRA(pixels, width: Int(width), height: Int(height)) else { return }
                eventSink(userData).continuation.yield(.railIcon(UInt64(id), png: png))
            },
            railDesktop: { userData, active, hasActive, order, count, hasOrder in
                let ids = hasOrder ? (order.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []) : nil
                eventSink(userData).continuation.yield(
                    .railDesktop(active: hasActive ? UInt64(active) : nil, order: ids?.map(UInt64.init)))
            })
    }
}

/// A window order out of the core, its title copied: the core keeps it only for the call
private func railOrder(_ window: VRCRailWindow) -> RailBridge.Order {
    let fields = window.fields
    func has(_ field: Int) -> Bool { fields & UInt32(field) != 0 }
    var order = RailBridge.Order(id: UInt64(window.id), created: window.created)
    if has(VRCRailFieldOwner) { order.owner = UInt64(window.owner) }
    if has(VRCRailFieldStyle) { order.style = window.style }
    if has(VRCRailFieldShow) { order.showState = window.showState }
    if has(VRCRailFieldTitle) { order.title = window.title.map { String(cString: $0) } ?? "" }
    if has(VRCRailFieldOffset) { order.offset = CGPoint(x: Int(window.x), y: Int(window.y)) }
    if has(VRCRailFieldSize) { order.size = CGSize(width: Int(window.width), height: Int(window.height)) }
    if has(VRCRailFieldVisibleOffset) {
        order.visibleOffset = CGPoint(x: Int(window.visibleX), y: Int(window.visibleY))
    }
    if has(VRCRailFieldVisibleRegion) {
        order.region = CGRect(
            x: Int(window.regionX), y: Int(window.regionY), width: Int(window.regionWidth),
            height: Int(window.regionHeight))
    }
    return order
}

/// BGRA pixels of the core as PNG, the form the model keeps icons in
private func pngOfBGRA(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> Data? {
    guard width > 0, height > 0,
        let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        let image = context.makeImage()
    else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// The pointer out of the core, with its pixels copied: the core keeps them only for the call
private func remotePointer(_ kind: VRCPointerKind, _ image: UnsafePointer<VRCPointerImage>?) -> RemotePointer {
    switch kind {
    case .hidden:
        return .hidden
    case .system:
        return .system
    case .image:
        guard let image = image?.pointee, let pixels = image.pixels else { return .system }
        let bytes = Data(bytes: pixels, count: Int(image.width) * Int(image.height) * 4)
        return .image(
            PointerImage(
                width: Int(image.width), height: Int(image.height), hotspotX: Int(image.hotspotX),
                hotspotY: Int(image.hotspotY), pixels: bytes))
    }
}

/// A free function: C function pointers cannot capture context, not even the type they are declared in
private func eventSink(_ userData: UnsafeMutableRawPointer?) -> EventSink {
    Unmanaged<EventSink>.fromOpaque(userData!).takeUnretainedValue()
}

/// Owns the session: destroying it waits for the session thread, so no callback outlives the sink
private final class SessionHandle {
    let session: OpaquePointer
    let sink: EventSink

    init(session: OpaquePointer, sink: EventSink) {
        self.session = session
        self.sink = sink
    }

    deinit {
        VRCSessionDestroy(session)
        sink.continuation.finish()
    }
}

/// Input goes to the core queue: the calls return at once, and input outside a connection is refused there
extension SessionController: DesktopInput {
    func mouseMoved(to point: DesktopPoint) {
        if let handle {
            _ = VRCSessionSendMouseMove(handle.session, point.x, point.y)
        }
    }

    func mouseButton(_ button: VRCMouseButton, pressed: Bool, at point: DesktopPoint) {
        if let handle {
            _ = VRCSessionSendMouseButton(handle.session, button, pressed, point.x, point.y)
        }
    }

    func mouseWheel(_ axis: VRCWheelAxis, delta: Int32, at point: DesktopPoint) {
        if let handle {
            _ = VRCSessionSendMouseWheel(handle.session, axis, delta, point.x, point.y)
        }
    }

    func key(_ key: UInt16, pressed: Bool, repeat: Bool) {
        if let handle {
            _ = VRCSessionSendKey(handle.session, key, pressed, `repeat`)
        }
    }

    /// The keypad of a Mac always types digits, so Num Lock is on for Windows to do the same
    func keyboardFocused(capsLock: Bool) {
        if let handle {
            _ = VRCSessionSendFocusIn(handle.session, capsLock, true)
        }
    }

    func keyboardLost() {
        if let handle {
            _ = VRCSessionReleaseKeys(handle.session)
        }
    }
}

/// The clipboard goes to the core directly: an offer and an answer return at once,
/// a copy waits for the server on the calling thread, as a paste on the Mac waits for its data,
/// and a copy of files runs on a thread of its own, since it may take minutes
extension SessionController: ClipboardChannel {
    func offerClipboard(_ formats: [VRCClipboardFormat]) {
        guard let handle else { return }
        formats.withUnsafeBufferPointer { _ = VRCSessionOfferClipboard(handle.session, $0.baseAddress, $0.count) }
    }

    func provideClipboardData(_ format: VRCClipboardFormat, data: Data?) {
        guard let handle else { return }
        guard let data else {
            _ = VRCSessionProvideClipboardData(handle.session, format, nil, 0)
            return
        }
        data.withUnsafeBytes { _ = VRCSessionProvideClipboardData(handle.session, format, $0.baseAddress, $0.count) }
    }

    func copyRemoteClipboard(_ format: VRCClipboardFormat, timeout: Duration) -> Data? {
        guard let handle else { return nil }
        var bytes: UnsafeMutableRawPointer?
        var length = 0
        let result = VRCSessionCopyRemoteClipboard(
            handle.session, format, Self.milliseconds(timeout), &bytes, &length)
        guard result == .OK, let bytes else { return nil }
        defer { free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    func copyRemoteFiles(to folder: URL, timeout: Duration, progress: FileCopyProgress) {
        guard let handle else {
            progress.finish(.invalidState)
            return
        }
        // The thread keeps the session alive: it ends only after the copy does
        let session = SendableHandle(handle: handle)
        let milliseconds = Self.milliseconds(timeout)
        let path = folder.path(percentEncoded: false)
        Thread.detachNewThread {
            let context = Unmanaged.passUnretained(progress).toOpaque()
            let result = withExtendedLifetime(progress) {
                VRCSessionCopyRemoteFiles(
                    session.handle.session, path, milliseconds,
                    { context, done, total in
                        guard let context else { return true }
                        return Unmanaged<FileCopyProgress>.fromOpaque(context).takeUnretainedValue()
                            .report(done: done, total: total)
                    }, context)
            }
            progress.finish(result)
        }
    }

    private static func milliseconds(_ duration: Duration) -> UInt32 {
        UInt32(
            clamping: duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The session handle for the thread of a copy of files: the core takes its calls from any thread
private struct SendableHandle: @unchecked Sendable {
    let handle: SessionHandle
}

/// C copies of the strings of one call, freed together once the call is over
/// An empty string is not given at all; the copies are cleared first, since some of them are passwords
private final class CStrings {
    private var copies: [(pointer: UnsafeMutablePointer<CChar>, length: Int)] = []

    func copy(_ string: String) -> UnsafePointer<CChar>? {
        guard !string.isEmpty, let pointer = strdup(string) else { return nil }
        copies.append((pointer, strlen(pointer)))
        return UnsafePointer(pointer)
    }

    deinit {
        for copy in copies {
            _ = memset_s(copy.pointer, copy.length, 0, copy.length)
            free(copy.pointer)
        }
    }
}
