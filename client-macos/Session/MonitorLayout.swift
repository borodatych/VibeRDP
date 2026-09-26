import CoreGraphics
import VibeRDPCore

/// The screens of the Mac as the monitors of one Windows desktop, for a session on all of them
///
/// Windows wants monitors that touch, the primary at 0,0, in its pixels; the Mac places its screens in points,
/// each with its own density; so the screens go side by side, in the order they stand on the Mac, left to right
/// when they stand side by side and top to bottom when they stand one over the other, aligned at the start
struct MonitorLayout: Equatable {
    /// One screen as a monitor: where it stands in the desktop, in pixels, and its scale
    struct Monitor: Equatable {
        var frame: CGRect
        var scale: UInt32
        var primary: Bool
    }

    /// In the order of the screens given
    let monitors: [Monitor]

    /// The rectangle around all monitors, where the frame of the engine starts at its top left
    var bounds: CGRect {
        monitors.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// The part of the frame of the engine a monitor shows: its place counted from the top left of all of them
    func region(of index: Int) -> CGRect {
        monitors[index].frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }

    /// The screens with their frames in points, their densities, and which one is the primary;
    /// sharp takes the pixels of each display, otherwise its points, as a single desktop does
    init(screens: [(frame: CGRect, backing: CGFloat)], primary: Int, sharp: Bool) {
        let sizes = screens.map { screen in
            let density = sharp ? max(screen.backing, 1) : 1
            return (
                size: CGSize(
                    width: (screen.frame.width * density).rounded(), height: (screen.frame.height * density).rounded()),
                scale: UInt32((density * CGFloat(DesktopRequest.standardScale)).rounded())
            )
        }
        // Side by side unless some two screens share a column of the Mac: then one over the other
        let frames = screens.map(\.frame)
        let stacked = frames.indices.contains { a in
            frames.indices.contains { b in
                a != b && frames[a].minX < frames[b].maxX && frames[b].minX < frames[a].maxX
            }
        }
        // The Mac counts up from the bottom, Windows down from the top: the topmost screen comes first
        let order = frames.indices.sorted {
            stacked ? frames[$0].maxY > frames[$1].maxY : frames[$0].minX < frames[$1].minX
        }
        var placed = [CGRect](repeating: .zero, count: screens.count)
        var position: CGFloat = 0
        for index in order {
            let size = sizes[index].size
            let start = stacked ? CGPoint(x: 0, y: position) : CGPoint(x: position, y: 0)
            placed[index] = CGRect(origin: start, size: size)
            position += stacked ? size.height : size.width
        }
        let origin = placed.indices.contains(primary) ? placed[primary].origin : .zero
        monitors = placed.indices.map { index in
            Monitor(
                frame: placed[index].offsetBy(dx: -origin.x, dy: -origin.y), scale: sizes[index].scale,
                primary: index == primary)
        }
    }

    /// The monitors as the core takes them
    var coreMonitors: [VRCMonitor] {
        monitors.map { monitor in
            VRCMonitor(
                x: Int32(monitor.frame.minX), y: Int32(monitor.frame.minY), width: UInt32(monitor.frame.width),
                height: UInt32(monitor.frame.height), scale: monitor.scale, primary: monitor.primary)
        }
    }
}
