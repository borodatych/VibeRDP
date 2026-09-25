import Carbon.HIToolbox
import IOSurface
import Metal
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// Real RDP exchanges on this Mac with the sample server of FreeRDP, built by core/scripts/build-test-server.sh
/// build-client.sh starts two of them and hands their sockets over:
/// VIBERDP_TEST_SERVER_SOCKET replays a RemoteFX recording of Windows Server 2008 R2,
/// VIBERDP_INTERACTIVE_SERVER_SOCKET draws its icon wherever a mouse event points and resizes its desktop on G
/// The servers listen on Unix sockets: no network, so no Local Network alert either
@MainActor
final class LiveServerTests: XCTestCase {
    private static let frameCount = 20
    private static let timeout: TimeInterval = 20
    private static let desktop = CGSize(width: 1024, height: 768)
    /// The size the interactive server switches to on G, as server/Sample/sfreerdp.c has it
    private static let resizedDesktop = CGSize(width: 800, height: 600)
    /// The recording goes from the Welcome screen through the desktop to the logoff screen
    /// From its seventh frame on, this pixel is blue: the teal of the logon screens or the sky of the wallpaper
    /// Swapped bytes turn either brown or orange; a corner would not do, desktop icons cover it
    private static let probe = (x: 700, y: 60)
    /// The interactive server draws its icon 10 pixels right of the event over a grey of 160 in every channel
    /// This pixel of the icon is teal, so it tells the icon from the background
    private static let iconProbe = (dx: 18, dy: 40)

    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testRecordedDesktopArrivesInItsColors() async throws {
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        let session = try start(socketIn: "VIBERDP_TEST_SERVER_SOCKET")
        let enoughFrames = await session.wait("\(Self.frameCount) frames", timeout: Self.timeout) {
            session.frames >= Self.frameCount
        }
        XCTAssertTrue(enoughFrames)

        XCTAssertEqual(session.states, [.connecting, .connected])
        XCTAssertEqual(session.failures, [])
        // The sample server speaks TLS, and without a name and a password the engine asks the app for them
        XCTAssertEqual(session.credentialsQuestions, 1)
        XCTAssertTrue(session.resized)
        let surface = try XCTUnwrap(session.controller.frameSurface())
        XCTAssertEqual(IOSurfaceGetWidth(surface), Int(Self.desktop.width))
        XCTAssertEqual(IOSurfaceGetHeight(surface), Int(Self.desktop.height))
        let pixel = try renderedProbe(of: surface, renderer: renderer)
        XCTAssertGreaterThan(Int(pixel.blue), Int(pixel.red) + 40, "\(pixel)")
        XCTAssertGreaterThan(Int(pixel.green), Int(pixel.red), "\(pixel)")

        await endsCleanly(session)
    }

    /// Every kind of pointer event reaches the server at its point: the icon appears where the event pointed
    func testPointerInputReachesTheServer() async throws {
        let session = try start(socketIn: "VIBERDP_INTERACTIVE_SERVER_SOCKET")
        let background = await session.wait("the first frame", timeout: Self.timeout) { session.frames > 0 }
        XCTAssertTrue(background)

        let input: DesktopInput = session.controller
        let steps: [(name: String, point: DesktopPoint, send: (DesktopPoint) -> Void)] = [
            ("move", DesktopPoint(x: 200, y: 150), { input.mouseMoved(to: $0) }),
            ("left click", DesktopPoint(x: 400, y: 300), { input.click(.left, at: $0) }),
            ("back button", DesktopPoint(x: 300, y: 500), { input.click(.back, at: $0) }),
            ("wheel", DesktopPoint(x: 600, y: 400), { input.mouseWheel(.vertical, delta: 120, at: $0) }),
            ("horizontal wheel", DesktopPoint(x: 800, y: 200), { input.mouseWheel(.horizontal, delta: -120, at: $0) }),
        ]
        for step in steps {
            step.send(step.point)
            let x = Int(step.point.x) + Self.iconProbe.dx
            let y = Int(step.point.y) + Self.iconProbe.dy
            let drawn = await session.wait("the icon after the \(step.name)", timeout: Self.timeout) {
                session.pixel(x: x, y: y).map { Int($0.blue) > Int($0.red) + 40 } ?? false
            }
            XCTAssertTrue(drawn, "\(step.name): \(String(describing: session.pixel(x: x, y: y)))")
        }
        XCTAssertEqual(session.failures, [])

        await endsCleanly(session)
    }

    /// A key reaches the server as its scan code: G switches the desktop of the interactive server to 800×600
    /// and back, and the second press waits in the queue until the server has reactivated the connection
    func testKeyReachesTheServer() async throws {
        let session = try start(socketIn: "VIBERDP_INTERACTIVE_SERVER_SOCKET")
        let first = await session.wait("the first frame", timeout: Self.timeout) { session.frames > 0 }
        XCTAssertTrue(first)

        let input: DesktopInput = session.controller
        let g = try XCTUnwrap(KeyCodeMap.scanCode(of: UInt16(kVK_ANSI_G), iso: false))
        input.keyboardFocused(capsLock: false)
        for size in [Self.resizedDesktop, Self.desktop] {
            input.key(g, pressed: true, repeat: false)
            input.key(g, pressed: false, repeat: false)
            let resized = await session.wait("a desktop of \(size)", timeout: Self.timeout) {
                session.desktopSize == size
            }
            XCTAssertTrue(resized, "\(String(describing: session.desktopSize))")
        }
        input.keyboardLost()
        XCTAssertEqual(session.failures, [])

        await endsCleanly(session)
    }

    /// Connects to the server whose socket the environment names, accepting its certificate
    private func start(socketIn variable: String) throws -> LiveSession {
        guard let socket = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("no test server: build it with core/scripts/build-test-server.sh, build-client.sh starts it")
        }
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let trusted = TrustedCertificates(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let session = LiveSession(trusted: trusted)
        let address = try XCTUnwrap(ServerAddress(socket))
        XCTAssertTrue(session.controller.connect(to: address, username: "", password: "", desktop: Self.desktop))
        return session
    }

    /// The user's disconnect ends a live session cleanly: Disconnected, and no error before it
    private func endsCleanly(_ session: LiveSession) async {
        session.controller.disconnect()
        let ended = await session.wait("Disconnected", timeout: Self.timeout) {
            session.states.last == .disconnected
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.states, [.connecting, .connected, .disconnected])
        XCTAssertEqual(session.failures, [])
    }

    /// Draws the surface at half size through the same renderer as the screen and reads the probe pixel back
    private func renderedProbe(of surface: IOSurfaceRef, renderer: FrameRenderer) throws
        -> (blue: UInt8, green: UInt8, red: UInt8)
    {
        let source = try XCTUnwrap(renderer.makeTexture(surface: surface))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: source.width / 2, height: source.height / 2, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        let destination = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        renderer.encode(source, into: destination, commandBuffer: commandBuffer)
        let sync = commandBuffer.makeBlitCommandEncoder()
        sync?.synchronize(resource: destination)
        sync?.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixel = [UInt8](repeating: 0, count: 4)
        let region = MTLRegionMake2D(Self.probe.x / 2, Self.probe.y / 2, 1, 1)
        destination.getBytes(&pixel, bytesPerRow: 4, from: region, mipmapLevel: 0)
        return (pixel[0], pixel[1], pixel[2])
    }
}

/// One live session and what it reported; a test waits on it until a condition holds after some event
@MainActor
private final class LiveSession {
    private(set) var states: [VRCSessionStateName] = []
    private(set) var failures: [VRCErrorKind] = []
    private(set) var frames = 0
    private(set) var credentialsQuestions = 0
    private(set) var resized = false
    /// The size of the last surface, in pixels
    private(set) var desktopSize: CGSize?
    private(set) var controller: SessionController!
    private var check: (() -> Void)?

    init(trusted: TrustedCertificates) {
        // Weak: the controller keeps this closure, and a strong reference would keep the session alive after the test
        controller = SessionController(trusted: trusted) { [weak self] event in
            self?.record(event)
        }
    }

    /// Suspends until the condition holds, checking it after every event; false when the time ran out first
    func wait(_ description: String, timeout: TimeInterval, until condition: @escaping () -> Bool) async -> Bool {
        if condition() {
            return true
        }
        let met = XCTestExpectation(description: description)
        check = { [weak self] in
            if condition() {
                self?.check = nil
                met.fulfill()
            }
        }
        let result = await XCTWaiter().fulfillment(of: [met], timeout: timeout)
        check = nil
        return result == .completed
    }

    /// A pixel of the desktop as the engine drew it
    func pixel(x: Int, y: Int) -> (blue: UInt8, green: UInt8, red: UInt8)? {
        guard let surface = controller.frameSurface(), x < IOSurfaceGetWidth(surface), y < IOSurfaceGetHeight(surface)
        else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let pixel = base + y * IOSurfaceGetBytesPerRow(surface) + x * 4
        return (pixel[0], pixel[1], pixel[2])
    }

    private func record(_ event: SessionController.Event) {
        switch event {
        case .state(let state):
            states.append(VRCSessionStateName(state))
        case .certificateQuestion:
            controller.answerCertificate(accept: true, remember: false)
        case .credentialsQuestion:
            // An empty answer goes on without credentials: the sample server has no logon of its own
            credentialsQuestions += 1
            controller.answerCredentials(username: "", password: "")
        case .frameResized(let width, let height):
            resized = true
            desktopSize = CGSize(width: Int(width), height: Int(height))
        case .frameUpdated:
            frames += 1
        case .failed(let kind, _):
            failures.append(kind)
        case .pointer:
            break
        }
        check?()
    }
}

extension DesktopInput {
    /// A press and a release at one point
    fileprivate func click(_ button: VRCMouseButton, at point: DesktopPoint) {
        mouseButton(button, pressed: true, at: point)
        mouseButton(button, pressed: false, at: point)
    }
}

/// Session states as plain values, so the sequence reads well in a failure message
private enum VRCSessionStateName: Equatable {
    case idle, connecting, connected, disconnected

    init(_ state: VRCSessionState) {
        switch state {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        }
    }
}
