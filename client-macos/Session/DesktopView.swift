import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import IOSurface
import QuartzCore
import VibeRDPCore

/// The remote desktop on screen: a CAMetalLayer redrawn from the engine surface whenever a frame changes
/// AppKit coalesces the redraw requests, so a burst of changed regions costs one draw per display refresh
/// The mouse over it goes to the input in desktop pixels, and the cursor is the pointer of the server
/// While it is the first responder of the key window, the keyboard goes to the input as well
@MainActor
final class DesktopView: NSView {
    private let renderer: FrameRenderer
    private var texture: MTLTexture?
    private var wheel = WheelAccumulator()
    private var cursor = NSCursor.arrow
    private var translator = KeyboardTranslator()
    private var keyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var isFirstResponder = false
    private(set) var hasKeyboard = false

    /// The session the mouse and the keyboard go to
    weak var input: DesktopInput?

    /// How keys are translated; without settings the keyboard stays with the Mac
    var keyboard: KeyboardSettingsSource? {
        didSet { updateKeyboard() }
    }

    /// The surface of the current desktop size; a resized desktop brings a new one
    var surface: IOSurfaceRef? {
        didSet {
            texture = surface.flatMap(renderer.makeTexture)
            needsDisplay = true
            updateCursor()
        }
    }

    /// The pointer of the server, shown as the cursor over the desktop
    var pointer = RemotePointer.system {
        didSet { updateCursor() }
    }

    init(renderer: FrameRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The visible rect is tracked as the view changes, so one area serves for good
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    /// Remote pixels are sRGB; an untagged layer would show them in the display space, too saturated on wide gamut
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return layer
    }

    /// Something in the frame changed: draw at the next display refresh
    func frameChanged() {
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func updateLayer() {
        guard let layer = layer as? CAMetalLayer, let texture, layer.drawableSize.width > 0,
            layer.drawableSize.height > 0, let drawable = layer.nextDrawable(),
            let commandBuffer = renderer.queue.makeCommandBuffer()
        else { return }
        renderer.encode(texture, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Mouse

    /// The first responder while connected: the keyboard comes here, not to the form underneath
    override var acceptsFirstResponder: Bool { true }

    /// The click that brings the window forward is a click on the remote desktop as well
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }

    override func mouseDown(with event: NSEvent) { button(.left, pressed: true, event) }
    override func mouseUp(with event: NSEvent) { button(.left, pressed: false, event) }
    override func rightMouseDown(with event: NSEvent) { button(.right, pressed: true, event) }
    override func rightMouseUp(with event: NSEvent) { button(.right, pressed: false, event) }

    override func otherMouseDown(with event: NSEvent) {
        if let other = Self.otherButton(event.buttonNumber) {
            button(other, pressed: true, event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if let other = Self.otherButton(event.buttonNumber) {
            button(other, pressed: false, event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = desktopPoint(of: event) else { return }
        let units = wheel.units(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        if units.vertical != 0 {
            input?.mouseWheel(.vertical, delta: units.vertical, at: point)
        }
        if units.horizontal != 0 {
            input?.mouseWheel(.horizontal, delta: units.horizontal, at: point)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    /// Buttons past the right one: AppKit counts the middle as 2 and the side buttons as 3 and 4
    static func otherButton(_ number: Int) -> VRCMouseButton? {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    private func moved(_ event: NSEvent) {
        if let point = desktopPoint(of: event) {
            input?.mouseMoved(to: point)
        }
    }

    private func button(_ button: VRCMouseButton, pressed: Bool, _ event: NSEvent) {
        if let point = desktopPoint(of: event) {
            input?.mouseButton(button, pressed: pressed, at: point)
        }
    }

    /// The desktop pixel under the event
    /// The view counts from the bottom left in points, the drawable from the top left in pixels
    private func desktopPoint(of event: NSEvent) -> DesktopPoint? {
        guard let layer = layer as? CAMetalLayer, let texture else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let scale = layer.contentsScale
        let drawablePoint = CGPoint(x: local.x * scale, y: (bounds.height - local.y) * scale)
        guard
            let pixel = FrameGeometry.desktopPixel(
                at: drawablePoint, source: CGSize(width: texture.width, height: texture.height),
                into: layer.drawableSize)
        else { return nil }
        return DesktopPoint(x: UInt32(pixel.x), y: UInt32(pixel.y))
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        updateKeyboard()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        updateKeyboard()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateKeyboard() }
                }
            }
        }
        updateKeyboard()
    }

    /// A key event while the desktop has the keyboard: true when it went to the input, false when the Mac keeps it
    /// The app monitors the events before it dispatches them, since otherwise the menus would take the ⌘ combinations
    /// and a key released while ⌘ is held would never reach the view
    func takesKey(_ event: NSEvent) -> Bool {
        guard hasKeyboard, event.window === window, let settings = keyboard?.settings,
            let translated = Self.translatorEvent(event)
        else { return false }

        var kept = false
        for action in translator.translate(translated, settings: settings) {
            switch action {
            case .send(let key, let pressed, let isRepeat):
                input?.key(key, pressed: pressed, repeat: isRepeat)
            case .passToMac:
                kept = true
            }
        }
        return !kept
    }

    static func translatorEvent(_ event: NSEvent) -> KeyboardTranslator.Event? {
        switch event.type {
        case .keyDown:
            .down(keyCode: event.keyCode, modifiers: Shortcut.Modifiers(event.modifierFlags), isRepeat: event.isARepeat)
        case .keyUp:
            .up(keyCode: event.keyCode)
        case .flagsChanged:
            .modifier(keyCode: event.keyCode, down: modifierDown(event))
        default:
            nil
        }
    }

    /// Bits of IOLLEvent.h that tell the left and the right modifier apart, with the flag both of them set
    private static let modifierBits: [UInt16: (device: UInt, flag: NSEvent.ModifierFlags)] = [
        UInt16(kVK_Control): (UInt(NX_DEVICELCTLKEYMASK), .control),
        UInt16(kVK_RightControl): (UInt(NX_DEVICERCTLKEYMASK), .control),
        UInt16(kVK_Shift): (UInt(NX_DEVICELSHIFTKEYMASK), .shift),
        UInt16(kVK_RightShift): (UInt(NX_DEVICERSHIFTKEYMASK), .shift),
        UInt16(kVK_Option): (UInt(NX_DEVICELALTKEYMASK), .option),
        UInt16(kVK_RightOption): (UInt(NX_DEVICERALTKEYMASK), .option),
        UInt16(kVK_Command): (UInt(NX_DEVICELCMDKEYMASK), .command),
        UInt16(kVK_RightCommand): (UInt(NX_DEVICERCMDKEYMASK), .command),
    ]

    /// Whether the modifier of a flags change went down: its own device bit says so
    /// An event without any device bits, as some keyboards and synthetic events send, falls back to the shared flag
    private static func modifierDown(_ event: NSEvent) -> Bool {
        guard let bits = modifierBits[event.keyCode] else { return false }
        let raw = event.modifierFlags.rawValue
        let anyDevice = modifierBits.values.reduce(UInt(0)) { $0 | $1.device }
        return raw & anyDevice == 0 ? event.modifierFlags.contains(bits.flag) : raw & bits.device != 0
    }

    /// The desktop has the keyboard while it is the first responder of the key window
    private func updateKeyboard() {
        let focused = isFirstResponder && window?.isKeyWindow == true && keyboard != nil
        guard focused != hasKeyboard else { return }
        hasKeyboard = focused
        if focused {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
                [weak self] event in
                let taken = MainActor.assumeIsolated { self?.takesKey(event) ?? false }
                return taken ? nil : event
            }
            input?.keyboardFocused(capsLock: NSEvent.modifierFlags.contains(.capsLock))
        } else {
            keyMonitor.map(NSEvent.removeMonitor)
            keyMonitor = nil
            translator.reset()
            input?.keyboardLost()
        }
    }

    // MARK: Cursor

    /// The cursor follows the pointer of the server and the size the desktop is drawn at
    private func updateCursor() {
        switch pointer {
        case .system:
            cursor = .arrow
        case .hidden:
            cursor = .invisible
        case .image(let image):
            cursor = image.cursor(pointsPerPixel: pointsPerDesktopPixel) ?? .arrow
        }
        // AppKit asks for the cursor only when the mouse enters: a change under a resting mouse is set here
        if let window, window.isKeyWindow {
            let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(mouse) {
                cursor.set()
            }
        }
    }

    /// Points of the screen that one desktop pixel takes: the drawable scale divided by the pixels in a point
    private var pointsPerDesktopPixel: CGFloat {
        guard let layer = layer as? CAMetalLayer, let texture, layer.contentsScale > 0 else { return 1 }
        let geometry = FrameGeometry.fit(
            source: CGSize(width: texture.width, height: texture.height), into: layer.drawableSize)
        return geometry.scale / layer.contentsScale
    }

    /// The drawable follows the view in pixels, so a desktop of the same pixel size is copied without scaling
    private func updateDrawableSize() {
        guard let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        needsDisplay = true
        updateCursor()
    }
}
