import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
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

    /// A changed frame reaches the screen through the display link, and a still one is not drawn again
    func testChangedFramesReachTheScreen() async {
        window.orderFront(nil)
        let first = await drawn(after: 0)
        XCTAssertTrue(first, "the frame of the new surface was never drawn")
        let drawnFrames = view.presentedFrames
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.presentedFrames, drawnFrames, "a still desktop was drawn again")
        view.frameChanged()
        let second = await drawn(after: drawnFrames)
        XCTAssertTrue(second, "the changed frame was never drawn")
    }

    /// Waits up to two seconds for the view to put more frames on screen than it had
    private func drawn(after count: Int) async -> Bool {
        for _ in 0..<200 where view.presentedFrames <= count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return view.presentedFrames > count
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

/// Key events of AppKit through the view: its monitor sees them before the menus, and it has the keyboard
/// only as the first responder of the key window
/// The window of these tests counts as key whatever app is in front, so they check the first responder part
@MainActor
final class DesktopKeyboardTests: XCTestCase {
    private static let extended = UInt16(VRC_KEY_EXTENDED)

    private var window: NSWindow!
    private var view: DesktopView!
    private var input: RecordingInput!
    private var suiteName = ""

    override func setUp() async throws {
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        view = DesktopView(renderer: renderer)
        input = RecordingInput()
        view.input = input
        view.keyboard = KeyboardSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        window.makeFirstResponder(view)
    }

    override func tearDown() async throws {
        window?.close()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testKeyboardFollowsTheFirstResponder() {
        XCTAssertTrue(view.hasKeyboard)
        XCTAssertEqual(input.events.first.map(\.isFocused), true)

        window.makeFirstResponder(nil)
        XCTAssertFalse(view.hasKeyboard)
        XCTAssertEqual(input.events.last, .lost)

        window.makeFirstResponder(view)
        XCTAssertTrue(view.hasKeyboard)
        XCTAssertEqual(input.events.last.map(\.isFocused), true)
    }

    /// ⌘C goes as Ctrl+C: the left ⌘ is known by its device bit
    func testCommandCopyGoesAsControlC() {
        input.clear()
        XCTAssertTrue(view.takesKey(flags(kVK_Command, [.command], device: UInt(NX_DEVICELCMDKEYMASK))))
        XCTAssertTrue(view.takesKey(key(.keyDown, kVK_ANSI_C, [.command])))
        XCTAssertTrue(view.takesKey(key(.keyUp, kVK_ANSI_C, [.command])))
        XCTAssertTrue(view.takesKey(flags(kVK_Command, [], device: 0)))
        XCTAssertEqual(
            input.events, [.key(0x1D, true), .key(0x2E, true), .key(0x2E, false), .key(0x1D, false)])
    }

    /// A combination the Mac keeps goes back to AppKit, and Windows gets nothing of it but the modifier
    func testMacShortcutGoesBackToAppKit() {
        input.clear()
        XCTAssertFalse(view.takesKey(key(.keyDown, kVK_ANSI_H, [.command])))
        XCTAssertEqual(input.events, [])
    }

    /// Without device bits the shared flag tells a press from a release
    func testModifierWithoutDeviceBits() {
        input.clear()
        XCTAssertTrue(view.takesKey(flags(kVK_RightOption, [.option], device: 0)))
        XCTAssertTrue(view.takesKey(flags(kVK_RightOption, [], device: 0)))
        XCTAssertEqual(input.events, [.key(Self.extended | 0x38, true), .key(Self.extended | 0x38, false)])
    }

    /// Events of AppKit reach the view by its monitor: the Close item of the menu does not take ⌘W,
    /// and the release arrives, though AppKit does not hand a key released under ⌘ to the view
    func testMonitorSeesEventsBeforeTheMenus() async {
        input.clear()
        for event in [key(.keyDown, kVK_ANSI_W, [.command]), key(.keyUp, kVK_ANSI_W, [.command])] {
            NSApp.postEvent(event, atStart: false)
        }
        let released = XCTestExpectation(description: "the release of W")
        input.onEvent = { event in
            if event == .key(0x11, false) {
                released.fulfill()
            }
        }
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(input.events, [.key(0x11, true), .key(0x11, false)])
        XCTAssertTrue(window.isVisible)
    }

    private func key(_ type: NSEvent.EventType, _ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode))!
    }

    private func flags(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, device: UInt) -> NSEvent {
        key(.flagsChanged, keyCode, NSEvent.ModifierFlags(rawValue: flags.rawValue | device))
    }
}

/// Key whatever app is in front: macOS 14 does not let a test bring its app forward while the user works in another
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Keeps what the view sent, in order
@MainActor
private final class RecordingInput: DesktopInput {
    enum Event: Equatable {
        case move(DesktopPoint)
        case button(VRCMouseButton, Bool, DesktopPoint)
        case wheel(VRCWheelAxis, Int32)
        case key(UInt16, Bool)
        case focused(capsLock: Bool)
        case lost

        var isFocused: Bool {
            if case .focused = self { true } else { false }
        }
    }

    private(set) var events: [Event] = [] {
        didSet { events.last.map { onEvent?($0) } }
    }
    var onEvent: ((Event) -> Void)?

    func clear() {
        events = []
    }

    func mouseMoved(to point: DesktopPoint) {
        events.append(.move(point))
    }

    func mouseButton(_ button: VRCMouseButton, pressed: Bool, at point: DesktopPoint) {
        events.append(.button(button, pressed, point))
    }

    func mouseWheel(_ axis: VRCWheelAxis, delta: Int32, at point: DesktopPoint) {
        events.append(.wheel(axis, delta))
    }

    func key(_ key: UInt16, pressed: Bool, repeat: Bool) {
        events.append(.key(key, pressed))
    }

    func keyboardFocused(capsLock: Bool) {
        events.append(.focused(capsLock: capsLock))
    }

    func keyboardLost() {
        events.append(.lost)
    }
}
