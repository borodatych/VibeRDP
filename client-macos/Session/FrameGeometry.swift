import CoreGraphics

/// Where the remote desktop lands in the drawable: scaled to fit with its proportions kept, centered between bars
struct FrameGeometry: Equatable {
    let scale: Double
    /// The destination pixels the desktop covers; the rest stays black
    let covered: CGRect

    static func fit(source: CGSize, into destination: CGSize) -> FrameGeometry {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else {
            return FrameGeometry(scale: 1, covered: .zero)
        }
        let scale = min(destination.width / source.width, destination.height / source.height)
        let width = (source.width * scale).rounded()
        let height = (source.height * scale).rounded()
        let offsetX = ((destination.width - width) / 2).rounded(.down)
        let offsetY = ((destination.height - height) / 2).rounded(.down)
        return FrameGeometry(scale: scale, covered: CGRect(x: offsetX, y: offsetY, width: width, height: height))
    }

    /// The desktop pixel under a point of the drawable, both counted from the top left corner
    /// The inverse of fit: a point over the bars lands on the nearest edge of the desktop; nil for empty sizes
    static func desktopPixel(at point: CGPoint, source: CGSize, into destination: CGSize) -> CGPoint? {
        let geometry = fit(source: source, into: destination)
        guard geometry.covered.width > 0, geometry.covered.height > 0 else { return nil }
        let x = ((point.x - geometry.covered.minX) / geometry.scale).rounded(.down)
        let y = ((point.y - geometry.covered.minY) / geometry.scale).rounded(.down)
        return CGPoint(x: min(max(x, 0), source.width - 1), y: min(max(y, 0), source.height - 1))
    }

    /// The pixel of the whole desktop under a point, for a view that shows a part of it
    /// Past the part the point goes on into the rest of the desktop: a drag that leaves the window of one monitor
    /// or of one window of the host goes on across the desktop, as it would on Windows; only its edges hold it
    static func desktopPixel(at point: CGPoint, part: CGRect, whole: CGSize, into destination: CGSize) -> CGPoint? {
        let geometry = fit(source: part.size, into: destination)
        guard geometry.covered.width > 0, geometry.covered.height > 0, whole.width > 0, whole.height > 0 else {
            return nil
        }
        let x = part.minX + ((point.x - geometry.covered.minX) / geometry.scale).rounded(.down)
        let y = part.minY + ((point.y - geometry.covered.minY) / geometry.scale).rounded(.down)
        return CGPoint(x: min(max(x, 0), whole.width - 1), y: min(max(y, 0), whole.height - 1))
    }
}
