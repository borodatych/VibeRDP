import VibeRDPCore
import XCTest

/// The app carries the core framework inside its bundle and reaches the engine through it
final class CoreFrameworkTests: XCTestCase {
    func testFrameworkLoadsFromTheAppBundle() throws {
        let core = try XCTUnwrap(Bundle(identifier: "tech.vibebrains.viberdp.core"), "the core framework is not loaded")
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL).resolvingSymlinksInPath().path
        XCTAssertTrue(
            core.bundleURL.resolvingSymlinksInPath().path.hasPrefix(frameworks + "/"),
            "the core framework loads from \(core.bundlePath), not from the app bundle")
    }

    func testSessionLifecycleThroughTheFramework() {
        var callbacks = VRCCallbacks(
            stateChanged: nil, error: nil, verifyCertificate: nil, frameResized: nil, frameUpdated: nil)
        let session = VRCSessionCreate(&callbacks, nil)
        XCTAssertNotNil(session)
        VRCSessionDestroy(session)
    }

    func testConnectRejectsMissingHost() {
        let session = VRCSessionCreate(nil, nil)
        defer { VRCSessionDestroy(session) }
        var params = VRCConnectionParams(
            host: nil, port: 0, width: 0, height: 0, username: nil, domain: nil, password: nil)
        XCTAssertEqual(VRCSessionConnect(session, &params), .invalidArgument)
    }
}
