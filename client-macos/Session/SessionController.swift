import Foundation
import IOSurface
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
    }

    private let trusted: TrustedCertificates
    private let onEvent: (Event) -> Void
    private var handle: SessionHandle?
    private var pendingCertificate: ServerCertificate?

    init(trusted: TrustedCertificates, onEvent: @escaping (Event) -> Void) {
        self.trusted = trusted
        self.onEvent = onEvent
    }

    /// Starts connecting with a desktop of the given size in pixels, through the gateway when there is one
    /// Empty credentials are not given at all: the engine asks for them when the server needs them
    /// False when the core refuses the parameters or cannot start
    func connect(
        to address: ServerAddress, username: String, password: String, gateway: GatewayParameters? = nil,
        desktop: CGSize
    ) -> Bool {
        guard handle == nil else { return false }
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
        params.width = UInt32(desktop.width)
        params.height = UInt32(desktop.height)
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
        case .certificate(let host, let port, let pem):
            Task { [weak self] in
                let examined = await Task.detached(priority: .userInitiated) {
                    ServerCertificate(host: host, port: port, pem: pem).map { ($0, CertificateTrust.evaluate($0)) }
                }.value
                self?.certificateExamined(examined)
            }
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
            })
    }
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
