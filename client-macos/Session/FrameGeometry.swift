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
}
