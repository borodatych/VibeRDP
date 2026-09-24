import Foundation
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
    }

    private let trusted: TrustedCertificates
    private let onEvent: (Event) -> Void
    private var handle: SessionHandle?
    private var pendingCertificate: ServerCertificate?

    init(trusted: TrustedCertificates, onEvent: @escaping (Event) -> Void) {
        self.trusted = trusted
        self.onEvent = onEvent
    }

    /// Starts connecting; false when the core refuses the parameters or cannot start
    func connect(to address: ServerAddress, username: String, password: String) -> Bool {
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
                        host: host, port: address.port ?? 0, username: user, domain: nil, password: secret)
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
            })
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

extension String {
    /// An empty field means the value is not given at all
    fileprivate func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        isEmpty ? body(nil) : withCString(body)
    }
}
