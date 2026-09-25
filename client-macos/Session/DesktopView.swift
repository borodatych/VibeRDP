import AppKit
import IOSurface
import QuartzCore

/// The remote desktop on screen: a CAMetalLayer redrawn from the engine surface whenever a frame changes
/// AppKit coalesces the redraw requests, so a burst of changed regions costs one draw per display refresh
@MainActor
final class DesktopView: NSView {
    private let renderer: FrameRenderer
    private var texture: MTLTexture?

    /// The surface of the current desktop size; a resized desktop brings a new one
    var surface: IOSurfaceRef? {
        didSet {
            texture = surface.flatMap(renderer.makeTexture)
            needsDisplay = true
        }
    }

    init(renderer: FrameRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    /// Remote pixels are sRGB; an untagged layer would show them in the display space, too saturated on wide gamut
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return layer
    }

    /// Something in the frame changed: draw at the next display refresh
    func frameChanged() {
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func updateLayer() {
        guard let layer = layer as? CAMetalLayer, let texture, layer.drawableSize.width > 0,
            layer.drawableSize.height > 0, let drawable = layer.nextDrawable(),
            let commandBuffer = renderer.queue.makeCommandBuffer()
        else { return }
        renderer.encode(texture, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The drawable follows the view in pixels, so a desktop of the same pixel size is copied without scaling
    private func updateDrawableSize() {
        guard let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        needsDisplay = true
    }
}
