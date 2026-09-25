import VibeRDPCore

/// A point of the remote desktop in its pixels, from the top left corner
struct DesktopPoint: Equatable {
    let x: UInt32
    let y: UInt32
}

/// Where the desktop view sends the mouse: the session of the connection, or a recorder in tests
@MainActor
protocol DesktopInput: AnyObject {
    func mouseMoved(to point: DesktopPoint)
    func mouseButton(_ button: VRCMouseButton, pressed: Bool, at point: DesktopPoint)
    /// The delta is in the units of Windows: 120 to a notch, positive up and right
    func mouseWheel(_ axis: VRCWheelAxis, delta: Int32, at point: DesktopPoint)
}
