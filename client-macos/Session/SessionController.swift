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

    /// Starts connecting with a desktop of the given size in pixels
    /// False when the core refuses the parameters or cannot start
    func connect(to address: ServerAddress, username: String, password: String, desktop: CGSize) -> Bool {
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

        let result = address.host.withCString { host in
            username.withOptionalCString { user in
                password.withOptionalCString { secret in
                    var params = VRCConnectionParams(
                        host: host, port: address.port ?? 0, width: UInt32(desktop.width),
                        height: UInt32(desktop.height), username: user, domain: nil, password: secret)
                    return VRCSessionConnect(session, &params)
                }
            }
        }
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

/// What the C callbacks hand over, copied out of memory that is valid only during the call
private enum CoreEvent: Sendable {
    case state(VRCSessionState)
    case failed(VRCErrorKind, name: String)
    case certificate(host: String, port: UInt16, pem: Data)
    case frameResized(width: UInt32, height: UInt32)
    case frameUpdated
    case pointer(RemotePointer)
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

extension String {
    /// An empty field means the value is not given at all
    fileprivate func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        isEmpty ? body(nil) : withCString(body)
    }
}
