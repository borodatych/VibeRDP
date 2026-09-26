import IOSurface
import Metal
import MetalPerformanceShaders

/// Draws the desktop surface into a texture: copied pixel for pixel, or scaled to fit between black bars
/// No shaders of its own, only a blit and a Metal Performance Shaders kernel, so the build needs no Metal toolchain
final class FrameRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let scaler: MPSImageBilinearScale

    /// Nil without a GPU, or with one that Metal Performance Shaders do not support, such as some virtual ones
    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, MPSSupportsMTLDevice(device), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.scaler = MPSImageBilinearScale(device: device)
    }

    /// A texture over the engine surface itself: the GPU reads the memory the engine writes, nothing is copied
    /// Managed storage works with every GPU of a Mac, the discrete ones included
    func makeTexture(surface: IOSurfaceRef) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
            mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    /// The destination needs render target and shader write usage: the bars are a clear, the scaling a compute pass
    /// region is the part of the source to draw, in its pixels, as one monitor of several shows its part of the desktop;
    /// nil draws all of it
    func encode(
        _ source: MTLTexture, region: CGRect? = nil, into destination: MTLTexture, commandBuffer: MTLCommandBuffer
    ) {
        let part = Self.part(of: source, region: region)
        // Only equal sizes allow a copy: a destination a pixel larger still scales, or the blit would be invalid
        if Int(part.width) == destination.width && Int(part.height) == destination.height {
            let blit = commandBuffer.makeBlitCommandEncoder()
            blit?.copy(
                from: source, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(part.minX), y: Int(part.minY), z: 0),
                sourceSize: MTLSize(width: Int(part.width), height: Int(part.height), depth: 1),
                to: destination, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit?.endEncoding()
            return
        }

        let geometry = FrameGeometry.fit(
            source: part.size, into: CGSize(width: destination.width, height: destination.height))
        clear(destination, commandBuffer: commandBuffer)
        // With a clip rectangle the kernel places the image from the clip origin: the offset lives in the clip alone,
        // and the pixels outside it keep the black of the clear; the translation moves the part to that origin
        var transform = MPSScaleTransform(
            scaleX: geometry.scale, scaleY: geometry.scale, translateX: -part.minX * geometry.scale,
            translateY: -part.minY * geometry.scale)
        scaler.clipRect = MTLRegion(
            origin: MTLOrigin(x: Int(geometry.covered.minX), y: Int(geometry.covered.minY), z: 0),
            size: MTLSize(width: Int(geometry.covered.width), height: Int(geometry.covered.height), depth: 1))
        // The kernel keeps the pointer only while encoding
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
            scaler.scaleTransform = nil
        }
    }

    /// The region within the source, whole pixels; nil or a region outside it is the whole source
    static func part(of source: MTLTexture, region: CGRect?) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let region else { return whole }
        let part = region.integral.intersection(whole)
        return part.isNull || part.isEmpty ? whole : part
    }

    /// A render pass with no draw calls: its load action alone paints the bars black
    private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
