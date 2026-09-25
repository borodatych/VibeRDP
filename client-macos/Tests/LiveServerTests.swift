import IOSurface
import Metal
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// A real RDP exchange on this Mac: the sample server of FreeRDP replays a RemoteFX recording of Windows Server 2008 R2
/// core/scripts/build-test-server.sh builds the server
/// build-client.sh starts it and hands its socket over in VIBERDP_TEST_SERVER_SOCKET
/// The server listens on a Unix socket: no network, so no Local Network alert either
@MainActor
final class LiveServerTests: XCTestCase {
    private static let frameCount = 20
    private static let timeout: TimeInterval = 20
    /// The recording goes from the Welcome screen through the desktop to the logoff screen
    /// From its seventh frame on, this pixel is blue: the teal of the logon screens or the sky of the wallpaper
    /// Swapped bytes turn either brown or orange; a corner would not do, desktop icons cover it
    private static let probe = (x: 700, y: 60)

    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testRecordedDesktopArrivesInItsColors() async throws {
        guard let socket = ProcessInfo.processInfo.environment["VIBERDP_TEST_SERVER_SOCKET"] else {
            throw XCTSkip("no test server: build it with core/scripts/build-test-server.sh, build-client.sh starts it")
        }
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }

        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let trusted = TrustedCertificates(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        var states: [VRCSessionStateName] = []
        var failures: [VRCErrorKind] = []
        var frames = 0
        var resized = false
        let enoughFrames = expectation(description: "\(Self.frameCount) frames")
        let ended = expectation(description: "disconnected")
        // Weak: the controller keeps this closure, and a strong reference would keep the session alive after the test
        weak var controller: SessionController?
        let session = SessionController(trusted: trusted) { event in
            switch event {
            case .state(let state):
                states.append(VRCSessionStateName(state))
                if state == .disconnected {
                    ended.fulfill()
                }
            case .certificateQuestion:
                controller?.answerCertificate(accept: true, remember: false)
            case .frameResized:
                resized = true
            case .frameUpdated:
                frames += 1
                if frames == Self.frameCount {
                    enoughFrames.fulfill()
                }
            case .failed(let kind, _):
                failures.append(kind)
            }
        }
        controller = session
        let address = try XCTUnwrap(ServerAddress(socket))
        let desktop = CGSize(width: 1024, height: 768)
        XCTAssertTrue(session.connect(to: address, username: "", password: "", desktop: desktop))
        await fulfillment(of: [enoughFrames], timeout: Self.timeout)

        XCTAssertEqual(states, [.connecting, .connected])
        XCTAssertEqual(failures, [])
        XCTAssertTrue(resized)
        let surface = try XCTUnwrap(session.frameSurface())
        XCTAssertEqual(IOSurfaceGetWidth(surface), Int(desktop.width))
        XCTAssertEqual(IOSurfaceGetHeight(surface), Int(desktop.height))
        let pixel = try renderedProbe(of: surface, renderer: renderer)
        XCTAssertGreaterThan(Int(pixel.blue), Int(pixel.red) + 40, "\(pixel)")
        XCTAssertGreaterThan(Int(pixel.green), Int(pixel.red), "\(pixel)")

        // The user's disconnect ends a live session cleanly: Disconnected, and no error before it
        session.disconnect()
        await fulfillment(of: [ended], timeout: Self.timeout)
        XCTAssertEqual(states, [.connecting, .connected, .disconnected])
        XCTAssertEqual(failures, [])
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
