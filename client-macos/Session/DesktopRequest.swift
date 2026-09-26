import CoreGraphics
import VibeRDPCore

/// The desktop a session asks the server for: its size in pixels of Windows and its scale in percent
/// On a Retina display a sharp desktop takes the pixels of the display and a scale that keeps the text as large
/// as the points would make it; otherwise the desktop takes the points, and the display stretches it
struct DesktopRequest: Equatable, Sendable {
    var size: CGSize
    var scale: UInt32
    /// Two or more spread the desktop over the screens of the Mac; the size is then the rectangle around them
    var monitors: [VRCMonitor] = []

    /// The scale of a desktop that is not stretched to a display of higher density
    static let standardScale: UInt32 = 100

    init(size: CGSize, scale: UInt32 = standardScale, monitors: [VRCMonitor] = []) {
        self.size = size
        self.scale = scale
        self.monitors = monitors
    }

    /// A desktop as large as an area of the Mac in points, at the pixels of its display when sharp
    static func points(_ points: CGSize, backing: CGFloat, sharp: Bool) -> DesktopRequest {
        guard sharp, backing > 1 else {
            return DesktopRequest(size: CGSize(width: points.width.rounded(), height: points.height.rounded()))
        }
        return DesktopRequest(
            size: CGSize(width: (points.width * backing).rounded(), height: (points.height * backing).rounded()),
            scale: UInt32((backing * CGFloat(standardScale)).rounded()))
    }
}

extension VRCMonitor: @retroactive Equatable, @unchecked @retroactive Sendable {
    public static func == (a: VRCMonitor, b: VRCMonitor) -> Bool {
        a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height && a.scale == b.scale
            && a.primary == b.primary
    }
}

