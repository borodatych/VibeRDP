import Foundation

/// An .icns file of PNG images: the icon of a bundle as the Finder, the Dock and Cmd-Tab read it
/// Each image goes under the type of its side; a side the format has no PNG type for is left out
enum IconFile {
    /// The PNG types of the format by the side of the image in pixels
    static let types: [Int: String] = [
        16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10",
    ]

    /// The file of the images given by side; nil when none has a side the format takes
    static func icns(_ images: [Int: Data]) -> Data? {
        let entries = images.keys.sorted().compactMap { side -> Data? in
            guard let type = types[side], let png = images[side] else { return nil }
            return Data(type.utf8) + bigEndian(UInt32(8 + png.count)) + png
        }
        guard !entries.isEmpty else { return nil }
        let body = entries.reduce(Data(), +)
        return Data("icns".utf8) + bigEndian(UInt32(8 + body.count)) + body
    }

    private static func bigEndian(_ number: UInt32) -> Data {
        withUnsafeBytes(of: number.bigEndian) { Data($0) }
    }
}
