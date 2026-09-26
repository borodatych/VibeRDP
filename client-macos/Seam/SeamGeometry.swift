import CoreGraphics

/// Where a window of the host stands on the Mac, in the Seam mode
///
/// The session lays its monitors out from the screens of the Mac, one monitor a screen, MonitorLayout;
/// so a place inside a monitor is the same place inside its screen, at the density of that screen
/// Windows counts in pixels down from the top of its primary monitor, the Mac in points up from the bottom
struct SeamGeometry: Equatable {
    let layout: MonitorLayout
    /// The frames of the screens in points, in the order of the monitors of the layout
    let screens: [CGRect]

    /// The frame of a window on the Mac, in points; nil when it touches no monitor
    /// A window over two monitors goes to the one that holds most of it, as Windows itself decides
    func macFrame(of rect: CGRect) -> CGRect? {
        guard layout.monitors.count == screens.count else { return nil }
        let areas = layout.monitors.map { monitor in
            let common = monitor.frame.intersection(rect)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        let monitor = layout.monitors[best].frame
        let screen = screens[best]
        let density = monitor.width / screen.width
        let local = CGRect(
            x: (rect.minX - monitor.minX) / density, y: (rect.minY - monitor.minY) / density,
            width: rect.width / density, height: rect.height / density)
        return CGRect(
            x: screen.minX + local.minX, y: screen.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// The rectangle on the host of a frame on the Mac, in pixels of Windows: the inverse of macFrame
    /// The frame goes to the screen that holds most of it; nil when it is on none of them
    func remoteRect(of frame: CGRect) -> CGRect? {
        guard layout.monitors.count == screens.count else { return nil }
        let areas = screens.map { screen in
            let common = screen.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        let monitor = layout.monitors[best].frame
        let screen = screens[best]
        let density = monitor.width / screen.width
        return CGRect(
            x: monitor.minX + ((frame.minX - screen.minX) * density).rounded(),
            y: monitor.minY + ((screen.maxY - frame.maxY) * density).rounded(),
            width: (frame.width * density).rounded(), height: (frame.height * density).rounded())
    }

    /// The part of the frame of the engine that shows the window: the frame starts at the top left of all monitors
    func region(of rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -layout.bounds.minX, dy: -layout.bounds.minY)
    }
}
