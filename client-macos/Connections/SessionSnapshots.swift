import AppKit
import IOSurface

/// The last picture of each connection, as its tile shows it: taken from the desktop as the session ends
/// The pictures live in the caches of the app, one PNG for each profile, and go with the profile
@MainActor
final class SessionSnapshots {
    /// Wide enough for a tile on a Retina display, small enough to keep a list of many light
    static let width = 640
    static let defaultRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "tech.vibebrains.viberdp", directoryHint: .isDirectory)
        .appending(path: "Snapshots", directoryHint: .isDirectory)

    let root: URL
    /// Pictures read once, until a new one replaces them
    private var images: [UUID: NSImage] = [:]

    init(root: URL = SessionSnapshots.defaultRoot) {
        self.root = root
    }

    func url(for id: UUID) -> URL {
        root.appending(path: "\(id.uuidString).png")
    }

    /// The picture of a profile, nil before its first session
    func image(for id: UUID) -> NSImage? {
        if let image = images[id] {
            return image
        }
        let image = NSImage(contentsOf: url(for: id))
        images[id] = image
        return image
    }

    /// Keeps the desktop as the picture of a profile; false when the surface could not be read or written
    @discardableResult
    func save(_ surface: IOSurfaceRef, for id: UUID) -> Bool {
        guard let png = Self.png(of: surface, width: Self.width) else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: url(for: id), options: .atomic)
        } catch {
            return false
        }
        images[id] = NSImage(data: png)
        return true
    }

    func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        images[id] = nil
    }

    /// The desktop scaled to a width, as PNG; the surface is BGRA with the alpha unused, as the engine draws it
    static func png(of surface: IOSurfaceRef, width: Int) -> Data? {
        let sourceWidth = IOSurfaceGetWidth(surface)
        let sourceHeight = IOSurfaceGetHeight(surface)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard
            let source = CGContext(
                data: IOSurfaceGetBaseAddress(surface), width: sourceWidth, height: sourceHeight,
                bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: space, bitmapInfo: info),
            let image = source.makeImage()
        else { return nil }
        let targetWidth = min(width, sourceWidth)
        let targetHeight = max(1, sourceHeight * targetWidth / sourceWidth)
        guard
            let target = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: info)
        else { return nil }
        target.interpolationQuality = .high
        target.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = target.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
