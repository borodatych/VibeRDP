import AppKit

/// What the server shows as its pointer; the desktop view turns it into the cursor over the desktop
enum RemotePointer: Equatable, Sendable {
    case image(PointerImage)
    case hidden
    case system
}

/// A server pointer: BGRA with straight alpha, rows top to bottom, as the core converts it
struct PointerImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let pixels: Data

    /// The cursor as large as the desktop is drawn: pointsPerPixel is the size of a desktop pixel on the screen
    func cursor(pointsPerPixel: CGFloat) -> NSCursor? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
            let provider = CGDataProvider(data: pixels as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        // B, G, R, A in memory is ARGB read little-endian; the alpha is straight, not premultiplied
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        let size = NSSize(width: CGFloat(width) * pointsPerPixel, height: CGFloat(height) * pointsPerPixel)
        // The hot spot counts from the top left corner, as NSCursor expects it; a server may put it past the edge
        let hotSpot = NSPoint(
            x: min(CGFloat(hotspotX) * pointsPerPixel, max(size.width - 1, 0)),
            y: min(CGFloat(hotspotY) * pointsPerPixel, max(size.height - 1, 0)))
        return NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: hotSpot)
    }
}

extension NSCursor {
    /// Draws nothing: the server hid its pointer, and NSCursor.hide() would hide the cursor everywhere
    @MainActor static let invisible = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
}
