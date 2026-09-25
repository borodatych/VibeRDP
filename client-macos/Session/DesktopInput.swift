import VibeRDPCore

/// A point of the remote desktop in its pixels, from the top left corner
struct DesktopPoint: Equatable {
    let x: UInt32
    let y: UInt32
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
