import VibeRDPCore

/// A point of the remote desktop in its pixels, from the top left corner
struct DesktopPoint: Equatable {
    let x: UInt32
    let y: UInt32
}

/// Who moves a window of the host on the Mac while the host drags it: the windows of the Seam mode
/// Between the start of the drag and the release the mouse moves the window here and nothing goes to the host
@MainActor
protocol LocalDragTarget: AnyObject {
    /// Whether the window of this view is dragged on the Mac now
    func isDragging(_ view: DesktopView) -> Bool
    /// The mouse moved with the button held, in screen coordinates
    func dragged(_ view: DesktopView, to point: CGPoint)
    /// The button went up: the drag ends, and the region of the frame where the window stands now comes back,
    /// for the release to land at the place of the host the mouse is over
    func released(_ view: DesktopView, at point: CGPoint) -> CGRect?
}

/// Where the desktop view sends the mouse and the keyboard: the session of the connection, or a recorder in tests
@MainActor
protocol DesktopInput: AnyObject {
    func mouseMoved(to point: DesktopPoint)
    func mouseButton(_ button: VRCMouseButton, pressed: Bool, at point: DesktopPoint)
    /// The delta is in the units of Windows: 120 to a notch, positive up and right
    func mouseWheel(_ axis: VRCWheelAxis, delta: Int32, at point: DesktopPoint)
    /// A key of the PC keyboard by its scan code, VRC_KEY_EXTENDED included
    func key(_ key: UInt16, pressed: Bool, repeat: Bool)
    /// The desktop got the keyboard: the server learns whether Caps Lock is on
    func keyboardFocused(capsLock: Bool)
    /// The desktop lost the keyboard: the keys still held on the server are released
    func keyboardLost()
}
