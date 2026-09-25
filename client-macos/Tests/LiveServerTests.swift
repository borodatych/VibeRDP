import Carbon.HIToolbox
import IOSurface
import Metal
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// Real RDP exchanges on this Mac with the sample server of FreeRDP, built by core/scripts/build-test-server.sh
/// build-client.sh starts three of them and hands their sockets over:
/// VIBERDP_TEST_SERVER_SOCKET replays a RemoteFX recording of Windows Server 2008 R2,
/// VIBERDP_INTERACTIVE_SERVER_SOCKET draws its icon wherever a mouse event points, resizes its desktop on G
/// and drops the connection on D,
/// VIBERDP_CLIPBOARD_SERVER_SOCKET takes the text, HTML, RTF, image and files the client offers and offers them back,
/// the text behind "echo: "
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

    /// A connection that drops as a network does is restored: D makes the interactive server close the transport
    /// with no error info, the session reconnects at once and serves input again
    /// X would not do: the server ends that session by the rules, and a session ended so is not restored
    func testDroppedConnectionIsRestored() async throws {
        let session = try start(socketIn: "VIBERDP_INTERACTIVE_SERVER_SOCKET")
        let first = await session.wait("the first frame", timeout: Self.timeout) { session.frames > 0 }
        XCTAssertTrue(first)

        let input: DesktopInput = session.controller
        let d = try XCTUnwrap(KeyCodeMap.scanCode(of: UInt16(kVK_ANSI_D), iso: false))
        input.key(d, pressed: true, repeat: false)
        input.key(d, pressed: false, repeat: false)
        let restored = await session.wait("the restored connection", timeout: Self.timeout) {
            session.states == [.connecting, .connected, .reconnecting, .connected]
        }
        XCTAssertTrue(restored, "\(session.states)")
        XCTAssertEqual(session.reconnectAttempts, 1)
        XCTAssertEqual(session.failures, [])

        // The restored connection takes input: the icon appears where the pointer went
        let point = DesktopPoint(x: 300, y: 200)
        input.mouseMoved(to: point)
        let drawn = await session.wait("the icon after the reconnection", timeout: Self.timeout) {
            session.pixel(x: Int(point.x) + Self.iconProbe.dx, y: Int(point.y) + Self.iconProbe.dy)
                .map { Int($0.blue) > Int($0.red) + 40 } ?? false
        }
        XCTAssertTrue(drawn)

        session.controller.disconnect()
        let ended = await session.wait("Disconnected", timeout: Self.timeout) { session.states.last == .disconnected }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.failures, [])
    }

    /// The clipboard makes the round trip through the echo server: text, HTML, RTF and an image of a private pasteboard
    /// go over and come back, and the paste on the Mac fetches each from the server while the paste waits
    /// The general pasteboard of this Mac is never touched
    func testClipboardRoundTrip() async throws {
        guard let socket = ProcessInfo.processInfo.environment["VIBERDP_CLIPBOARD_SERVER_SOCKET"] else {
            throw XCTSkip("no clipboard test server: build it with core/scripts/build-test-server.sh")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tech.vibebrains.viberdp.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("Привет\nмир 👋", forType: .string)
        item.setData(Data("<p>Жирный <b>текст</b></p>".utf8), forType: .html)
        item.setData(Data(#"{\rtf1\ansi \b bold\b0 }"#.utf8), forType: .rtf)
        item.setData(TestImage.tiff, forType: .tiff)
        pasteboard.writeObjects([item])

        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let trusted = TrustedCertificates(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let session = LiveSession(trusted: trusted)
        let address = try XCTUnwrap(ServerAddress(socket))
        // The sample server has no logon of its own: a name and a password spare the question
        XCTAssertTrue(
            session.controller.connect(to: address, username: "tester", password: "unused", desktop: Self.desktop))
        let bridge = ClipboardBridge(pasteboard: pasteboard, channel: session.controller)
        session.clipboard = bridge
        bridge.start()

        let echoed = await session.wait("the echo of the clipboard", timeout: Self.timeout) {
            session.remoteClipboards > 0
        }
        XCTAssertTrue(echoed)
        XCTAssertEqual(pasteboard.string(forType: .string), "echo: Привет\nмир 👋")
        let html = try XCTUnwrap(pasteboard.data(forType: .html))
        XCTAssertEqual(
            String(data: html, encoding: .utf8),
            #"<meta charset="utf-8"><html><body><!--StartFragment--><p>Жирный <b>текст</b></p>"#
                + "<!--EndFragment--></body></html>")
        XCTAssertEqual(pasteboard.data(forType: .rtf), Data(#"{\rtf1\ansi \b bold\b0 }"#.utf8))
        XCTAssertTrue(TestImage.matches(try XCTUnwrap(pasteboard.data(forType: .png))))
        XCTAssertTrue(TestImage.matches(try XCTUnwrap(pasteboard.data(forType: .tiff))))
        XCTAssertEqual(session.failures, [])

        bridge.stop()
        XCTAssertNil(pasteboard.string(forType: .string), "the item for the remote clipboard goes with the session")
        await endsCleanly(session)
    }

    /// Files make the round trip through the echo server: a folder and a file of the Mac go over by their contents,
    /// come back as the remote clipboard, and the paste on the Mac brings them into the staging folder
    /// The copy waits over the panel of the app, as it does when Finder pastes
    func testClipboardFilesRoundTrip() async throws {
        guard let socket = ProcessInfo.processInfo.environment["VIBERDP_CLIPBOARD_SERVER_SOCKET"] else {
            throw XCTSkip("no clipboard test server: build it with core/scripts/build-test-server.sh")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "viberdp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = folder.appending(path: "mac")
        try FileManager.default.createDirectory(at: mac.appending(path: "Папка"), withIntermediateDirectories: true)
        try Data("квартал".utf8).write(to: mac.appending(path: "Папка/отчёт.txt"))
        try Data("note".utf8).write(to: mac.appending(path: "note.txt"))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tech.vibebrains.viberdp.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([mac.appending(path: "Папка") as NSURL, mac.appending(path: "note.txt") as NSURL])

        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let trusted = TrustedCertificates(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let session = LiveSession(trusted: trusted)
        let address = try XCTUnwrap(ServerAddress(socket))
        XCTAssertTrue(
            session.controller.connect(to: address, username: "tester", password: "unused", desktop: Self.desktop))
        let staging = FileStaging(root: folder.appending(path: "staging"))
        let bridge = ClipboardBridge(pasteboard: pasteboard, channel: session.controller, staging: staging)
        session.clipboard = bridge
        bridge.start()

        let echoed = await session.wait("the echo of the files", timeout: Self.timeout) {
            session.remoteClipboards > 0
        }
        XCTAssertTrue(echoed)
        let urls = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Папка", "note.txt"])
        XCTAssertTrue(
            urls.allSatisfy { $0.path(percentEncoded: false).hasPrefix(staging.root.path(percentEncoded: false)) })
        XCTAssertEqual(try String(contentsOf: urls[0].appending(path: "отчёт.txt"), encoding: .utf8), "квартал")
        XCTAssertEqual(try String(contentsOf: urls[1], encoding: .utf8), "note")
        XCTAssertEqual(session.failures, [])

        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path(percentEncoded: false)))
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
    private(set) var reconnectAttempts = 0
    private(set) var remoteClipboards = 0
    private(set) var resized = false
    /// The bridge a clipboard test gives the session, fed with the clipboard events
    var clipboard: ClipboardBridge?
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
        case .gatewayMessage:
            break
        case .reconnecting:
            reconnectAttempts += 1
        case .frameResized(let width, let height):
            resized = true
            desktopSize = CGSize(width: Int(width), height: Int(height))
        case .frameUpdated:
            frames += 1
        case .failed(let kind, _):
            failures.append(kind)
        case .pointer:
            break
        case .remoteClipboard(let formats):
            remoteClipboards += 1
            clipboard?.remoteClipboardChanged(formats)
        case .clipboardDataRequested(let format):
            clipboard?.dataRequested(format)
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
    case idle, connecting, connected, disconnected, reconnecting

    init(_ state: VRCSessionState) {
        switch state {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .reconnecting: self = .reconnecting
        }
    }
}
