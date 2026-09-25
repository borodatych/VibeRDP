import AppKit
import IOSurface
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// Mouse events of AppKit turned into desktop input: a window of the desktop size makes a point its own pixel
/// whatever the scale of the screen, since the drawable and the view scale alike
@MainActor
final class DesktopViewTests: XCTestCase {
    private static let size = NSSize(width: 1024, height: 768)

    private var window: NSWindow!
    private var view: DesktopView!
    private var input: RecordingInput!

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        view = DesktopView(renderer: renderer)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: Int(Self.size.width), kIOSurfaceHeight: Int(Self.size.height),
            kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: 0x4247_5241,
        ]
        view.surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
        input = RecordingInput()
        view.input = input
    }

    override func tearDown() async throws {
        window?.close()
    }

    /// The view counts from the bottom left, the desktop from the top left
    func testClickLandsOnThePixelUnderIt() {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 668)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 668)))
        let point = DesktopPoint(x: 100, y: 100)
        XCTAssertEqual(input.events, [.button(.left, true, point), .button(.left, false, point)])
    }

    /// The top row of the desktop is the top point of the view, from 767 to 768; past the edges the point is clamped
    func testRightButtonAndDragging() {
        view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: NSPoint(x: 0.5, y: 767.5)))
        view.rightMouseDragged(with: mouseEvent(.rightMouseDragged, at: NSPoint(x: 1023, y: 0)))
        view.rightMouseUp(with: mouseEvent(.rightMouseUp, at: NSPoint(x: 1023, y: 0)))
        XCTAssertEqual(
            input.events,
            [
                .button(.right, true, DesktopPoint(x: 0, y: 0)), .move(DesktopPoint(x: 1023, y: 767)),
                .button(.right, false, DesktopPoint(x: 1023, y: 767)),
            ])
    }

    func testOtherButtonsAreMiddleBackAndForward() {
        XCTAssertEqual(DesktopView.otherButton(2), .middle)
        XCTAssertEqual(DesktopView.otherButton(3), .back)
        XCTAssertEqual(DesktopView.otherButton(4), .forward)
        XCTAssertNil(DesktopView.otherButton(5))
    }

    /// A classic wheel reports lines, and each goes as a notch of 120
    func testWheelLinesBecomeNotches() throws {
        let scroll = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertEqual(input.events.count, 1)
        guard case .wheel(let axis, let delta)? = input.events.first else { return XCTFail("\(input.events)") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(delta, 240)
    }

    func testNoSurfaceNoInput() {
        view.surface = nil
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
        XCTAssertEqual(input.events, [])
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// Keeps what the view sent, in order
@MainActor
private final class RecordingInput: DesktopInput {
    enum Event: Equatable {
        case move(DesktopPoint)
        case button(VRCMouseButton, Bool, DesktopPoint)
        case wheel(VRCWheelAxis, Int32)
    }

    private(set) var events: [Event] = []

    func mouseMoved(to point: DesktopPoint) {
        events.append(.move(point))
    }

    func mouseButton(_ button: VRCMouseButton, pressed: Bool, at point: DesktopPoint) {
        events.append(.button(button, pressed, point))
    }

    func mouseWheel(_ axis: VRCWheelAxis, delta: Int32, at point: DesktopPoint) {
        events.append(.wheel(axis, delta))
    }
}
