import IOSurface
import Metal
import XCTest

@testable import VibeRDP

/// Draws a synthetic engine surface on the GPU and reads the pixels back
/// The surface is 4x4 in four 2x2 quadrants, so bilinear sampling at quadrant centers stays inside one color
final class FrameRendererTests: XCTestCase {
    /// BGRA bytes, as the engine writes them
    private static let quadrants: [[UInt8]] = [
        [0, 0, 255, 255],  // red, top left
        [0, 255, 0, 255],  // green, top right
        [255, 0, 0, 255],  // blue, bottom left
        [255, 255, 255, 255],  // white, bottom right
    ]
    private static let black: [UInt8] = [0, 0, 0, 255]

    private var renderer: FrameRenderer!

    override func setUpWithError() throws {
        // A macOS virtual machine may run without a GPU: the test skips with the reason instead of failing
        guard let renderer = FrameRenderer() else {
            throw XCTSkip("no GPU that runs Metal Performance Shaders on this machine")
        }
        self.renderer = renderer
    }

    func testSameSizeCopiesEveryPixel() throws {
        let pixels = try render(destinationWidth: 4, destinationHeight: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(pixel(pixels, width: 4, x: x, y: y), Self.quadrant(x: x, y: y, size: 4), "(\(x), \(y))")
            }
        }
    }

    func testDoubleSizeKeepsTheQuadrants() throws {
        let pixels = try render(destinationWidth: 8, destinationHeight: 8)
        XCTAssertEqual(pixel(pixels, width: 8, x: 1, y: 1), Self.quadrants[0])
        XCTAssertEqual(pixel(pixels, width: 8, x: 6, y: 1), Self.quadrants[1])
        XCTAssertEqual(pixel(pixels, width: 8, x: 1, y: 6), Self.quadrants[2])
        XCTAssertEqual(pixel(pixels, width: 8, x: 6, y: 6), Self.quadrants[3])
    }

    /// A wider drawable keeps the proportions: the desktop sits in the middle between black bars
    func testWiderDestinationGetsBlackBars() throws {
        let pixels = try render(destinationWidth: 8, destinationHeight: 4)
        for y in 0..<4 {
            for x in [0, 1, 6, 7] {
                XCTAssertEqual(pixel(pixels, width: 8, x: x, y: y), Self.black, "bar at (\(x), \(y))")
            }
        }
        XCTAssertEqual(pixel(pixels, width: 8, x: 2, y: 0), Self.quadrants[0])
        XCTAssertEqual(pixel(pixels, width: 8, x: 5, y: 3), Self.quadrants[3])
    }

    /// One pixel more than the desktop is no longer a copy: the desktop is drawn at scale 1 with a bar below
    func testOnePixelTallerIsNotACopy() throws {
        let pixels = try render(destinationWidth: 4, destinationHeight: 5)
        XCTAssertEqual(pixel(pixels, width: 4, x: 0, y: 0), Self.quadrants[0])
        XCTAssertEqual(pixel(pixels, width: 4, x: 3, y: 3), Self.quadrants[3])
        XCTAssertEqual(pixel(pixels, width: 4, x: 0, y: 4), Self.black)
    }

    /// One monitor of several shows its part of the desktop: at its size a copy, larger a scale, both of that part only
    func testRegionShowsItsPartOnly() throws {
        let copy = try render(destinationWidth: 2, destinationHeight: 2, region: CGRect(x: 2, y: 2, width: 2, height: 2))
        for y in 0..<2 {
            for x in 0..<2 {
                XCTAssertEqual(pixel(copy, width: 2, x: x, y: y), Self.quadrants[3], "copy (\(x), \(y))")
            }
        }
        let scaled = try render(destinationWidth: 4, destinationHeight: 4, region: CGRect(x: 2, y: 0, width: 2, height: 2))
        // Bilinear sampling at the edges of a part takes in the pixels beside it: the inside is the part alone
        XCTAssertEqual(pixel(scaled, width: 4, x: 1, y: 1), Self.quadrants[1])
        XCTAssertEqual(pixel(scaled, width: 4, x: 2, y: 2), Self.quadrants[1])
        let right = try render(destinationWidth: 2, destinationHeight: 4, region: CGRect(x: 2, y: 0, width: 2, height: 4))
        XCTAssertEqual(pixel(right, width: 2, x: 0, y: 0), Self.quadrants[1])
        XCTAssertEqual(pixel(right, width: 2, x: 1, y: 3), Self.quadrants[3])
    }

    private static func quadrant(x: Int, y: Int, size: Int) -> [UInt8] {
        quadrants[(y < size / 2 ? 0 : 2) + (x < size / 2 ? 0 : 1)]
    }

    private func render(destinationWidth: Int, destinationHeight: Int, region: CGRect? = nil) throws -> [UInt8] {
        let surface = try makeSurface()
        let source = try XCTUnwrap(renderer.makeTexture(surface: surface))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: destinationWidth, height: destinationHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        let destination = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))

        let commandBuffer = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        renderer.encode(source, region: region, into: destination, commandBuffer: commandBuffer)
        let sync = commandBuffer.makeBlitCommandEncoder()
        sync?.synchronize(resource: destination)
        sync?.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var pixels = [UInt8](repeating: 0, count: destinationWidth * destinationHeight * 4)
        destination.getBytes(
            &pixels, bytesPerRow: destinationWidth * 4,
            from: MTLRegionMake2D(0, 0, destinationWidth, destinationHeight), mipmapLevel: 0)
        return pixels
    }

    /// The same kind of surface the core makes: BGRA, rows as the system aligns them
    private func makeSurface() throws -> IOSurfaceRef {
        let size = 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: size, kIOSurfaceHeight: size, kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241,
        ]
        let surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<size {
            for x in 0..<size {
                let color = Self.quadrant(x: x, y: y, size: size)
                for channel in 0..<4 {
                    base[y * bytesPerRow + x * 4 + channel] = color[channel]
                }
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }

    private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        Array(pixels[(y * width + x) * 4..<(y * width + x) * 4 + 4])
    }
}
