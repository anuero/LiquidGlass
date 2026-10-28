import UIKit
import Metal
import CoreVideo

/// How the backdrop gets into a texture.
///
/// There is deliberately no `.automatic`: measurement (see `LiquidGlassBackdrop`)
/// found the private path never faster and sometimes three times slower, so an
/// "automatic" choice would only ever be a trap that picks the bad one.
public enum LiquidGlassCaptureMode {
    /// Public only: walk and re-rasterize the source view's layer tree.
    case viewTree
    /// Rasterize the composited backdrop via a private `CABackdropLayer`.
    /// Opt in only for a backdrop the public path cannot draw.
    case compositedBackdrop
}

/// Captures whatever is behind the glass into a GPU texture, plus a mip pyramid
/// used as the frost.
///
/// Glass views must be siblings above `sourceView`, never inside it.
///
/// **Capture modes.** `.viewTree` (the default) re-runs Core Graphics over every
/// layer of `sourceView` each frame. It cannot draw `UIVisualEffectView`,
/// `AVPlayerLayer` or other `CAMetalLayer` content, those come out blank.
///
/// `.compositedBackdrop` parks a private `CABackdropLayer` directly above
/// `sourceView`, lets the render server fill it with the real composited
/// backdrop, and rasterizes that. It sees video and blur views correctly.
///
/// It is **not** faster. Full-screen live capture at captureScale 0.5, median of
/// 120 captures:
///
///     iOS 18.0 sim    viewTree 9.08 ms / 60 fps    composited  9.59 ms / 60 fps
///     iOS 26.2 sim    viewTree ~10.3 ms / 60 fps   composited 33.31 ms / 23 fps
///
/// `drawHierarchy` goes through UIKit's snapshot machinery rather than blitting a
/// ready surface, so the composited path pays that instead of the tree walk, and
/// on 26.2 that path got far more expensive. A much deeper view hierarchy may
/// tip the balance; measure it with `medianCaptureMilliseconds` first.
///
/// It is also private API: App Store static analysis flags it. If the render
/// server hands back nothing, the capture falls back to `.viewTree` and latches
/// there rather than rendering a black backdrop.
public final class LiquidGlassBackdrop {

    /// The content the glass refracts.
    public weak var sourceView: UIView?

    /// Capture resolution as a fraction of native screen scale. 0.5 on a 3x
    /// screen means the backdrop is captured at 1.5x, plenty, because the only
    /// thing that reads it sharply is the thin rim lens.
    /// This is the perf dial: cost is linear in captureScale².
    public var captureScale: CGFloat = 0.5 {
        didSet { if captureScale != oldValue { invalidateTextures() } }
    }

    /// Re-capture every frame. Turn off for a static backdrop and call
    /// `setNeedsCapture()` yourself.
    /// on by default, and it is the biggest cost: the main thread re-rasterizes the source every
    /// frame even at rest. with it off an idle screen costs nothing, the engine sleeps
    public var isLive: Bool = true {
        didSet { if isLive && !oldValue { LiquidGlassEngine.shared?.wake() } }
    }

    /// Region of `sourceView` to capture, in its coordinates.
    ///
    /// `nil` (the default) means "work it out": the union of the glass views
    /// drawing off this backdrop, grown by their blur and refraction reach and
    /// snapped to a 32pt grid. Cost is linear in area and most apps put glass on
    /// a fraction of the screen, so this is usually the single biggest saving.
    /// On an iOS 18 simulator, median of 120 captures: 9.17 ms with glass over the
    /// whole screen, 4.21 ms for a tab bar alone.
    ///
    /// It is one bounding box, so glass at both the top *and* bottom of a screen
    /// still costs the whole screen. Give those two separate backdrops.
    public var captureRect: CGRect? {
        didSet { if captureRect != oldValue { invalidateTextures() } }
    }

    /// Defaults to the public path: the private one is no faster (see the type
    /// doc for numbers) and costs you App Store risk.
    public var captureMode: LiquidGlassCaptureMode = .viewTree {
        didSet {
            guard captureMode != oldValue else { return }
            compositedIsBroken = false
            teardownCompositedView()
            samples.removeAll()
            sampleCursor = 0
            setNeedsCapture()
        }
    }

    /// What the last capture actually used. Differs from `captureMode` only when
    /// the composited path returned nothing and fell back.
    public private(set) var activeCaptureMode: LiquidGlassCaptureMode = .viewTree

    /// Milliseconds spent in the last CPU capture.
    public private(set) var lastCaptureMilliseconds: Double = 0

    /// Median of the last 120 captures. Compare capture paths with this one; a
    /// single frame's number is noise.
    public var medianCaptureMilliseconds: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.sorted()[samples.count / 2]
    }
    private var samples: [Double] = []
    private var sampleCursor = 0

    // MARK: Internals

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var slots: [CaptureSlot] = []
    private var slotIndex = 0
    private(set) var pyramid: MTLTexture?
    private(set) var pyramidLevelViews: [MTLTexture] = []
    private(set) var effectiveRect: CGRect = .zero
    private(set) var pixelScale: CGFloat = 1
    private var needsCapture = true
    private var compositedIsBroken = false
    private var compositedView: CompositedBackdropView?

    /// Holds the `CVMetalTexture` alongside the `MTLTexture`: releasing the
    /// wrapper invalidates the texture the GPU is still reading.
    private struct CaptureSlot {
        let pixelBuffer: CVPixelBuffer
        let bridge: CVMetalTexture
        let texture: MTLTexture
    }

    /// `nil` when Metal is unavailable; glass views without a backdrop fall back
    /// to `UIVisualEffectView`.
    public init?(sourceView: UIView) {
        guard let engine = LiquidGlassEngine.shared else { return nil }
        self.sourceView = sourceView
        self.device = engine.device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if textureCache == nil { return nil }
    }

    deinit { compositedView?.removeFromSuperview() }

    public func setNeedsCapture() {
        needsCapture = true
        LiquidGlassEngine.shared?.wake()
    }

    var wantsCapture: Bool { needsCapture || isLive }

    func invalidateTextures() {
        slots.removeAll()
        pyramid = nil
        pyramidLevelViews.removeAll()
        setNeedsCapture()
    }

    var sharpTexture: MTLTexture? { slots.isEmpty ? nil : slots[slotIndex].texture }

    /// Points covered by the capture. The shader maps view coordinates through it.
    var captureSizeInPoints: CGSize { effectiveRect.size }

    // MARK: Capture

    /// Redraws the backdrop into the current slot. Main thread: both capture
    /// paths are UIKit.
    func captureIfNeeded() -> Bool {
        guard let source = sourceView else { return false }
        let rect = captureRect ?? autoCaptureRect(in: source)
        guard rect.width > 0, rect.height > 0 else { return false }

        let screenScale = source.window?.screen.scale ?? UIScreen.main.scale
        let scale = max(0.25, min(captureScale, 1.0)) * screenScale
        // Reallocate on a size change only: a glass view being dragged moves the
        // rect every frame, and rebuilding the pyramid for that would cost far
        // more than the capture itself.
        if slots.isEmpty || rect.size != effectiveRect.size || scale != pixelScale {
            effectiveRect = rect
            pixelScale = scale
            guard allocate() else { return false }
            needsCapture = true
        }
        effectiveRect = rect
        guard needsCapture || isLive else { return false }
        needsCapture = false

        slotIndex = (slotIndex + 1) % slots.count
        let buffer = slots[slotIndex].pixelBuffer
        let start = CACurrentMediaTime()

        let wantsComposited = (captureMode == .compositedBackdrop) && !compositedIsBroken
        var used = LiquidGlassCaptureMode.viewTree

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = makeContext(for: buffer) {
            context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.saveGState()
            // Core Graphics is bottom-left origin; UIKit drawing expects the
            // flipped context that UIGraphicsBeginImageContext would have made.
            context.translateBy(x: 0, y: CGFloat(context.height))
            context.scaleBy(x: pixelScale, y: -pixelScale)
            context.translateBy(x: -effectiveRect.origin.x, y: -effectiveRect.origin.y)

            if wantsComposited, drawComposited(into: context, source: source) {
                used = .compositedBackdrop
            } else {
                drawViewTree(into: context, source: source)
            }
            context.restoreGState()

            if used == .compositedBackdrop, isBlank(buffer) {
                // The render server handed back nothing. Latch to the public path
                // instead of retrying, and re-draw now, so no frame is black.
                compositedIsBroken = true
                teardownCompositedView()
                context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(context.height))
                context.scaleBy(x: pixelScale, y: -pixelScale)
                context.translateBy(x: -effectiveRect.origin.x, y: -effectiveRect.origin.y)
                drawViewTree(into: context, source: source)
                context.restoreGState()
                used = .viewTree
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        activeCaptureMode = used
        lastCaptureMilliseconds = (CACurrentMediaTime() - start) * 1000
        if samples.count < 120 {
            samples.append(lastCaptureMilliseconds)
        } else {
            samples[sampleCursor] = lastCaptureMilliseconds
            sampleCursor = (sampleCursor + 1) % 120
        }
        return true
    }

    /// `render(in:)`, deliberately, despite WWDC 2013 s226 putting
    /// `drawHierarchy(afterScreenUpdates: false)` at "up to 8x" faster. Measured
    /// here it is slower, both full-screen and cropped (iOS 18 sim, median of
    /// 120 captures):
    ///
    ///                       full screen   tab bar strip
    ///     render(in:)          9.14 ms        4.62 ms
    ///     drawHierarchy       10.50 ms        7.84 ms
    ///
    /// The gap widens when cropped, which says drawHierarchy snapshots the whole
    /// view and the context clip does not cull its work, exactly the property
    /// that matters here, since a small capture rect is the main lever.
    private func drawViewTree(into context: CGContext, source: UIView) {
        source.layer.render(in: context)
    }

    /// Without an explicit `captureRect`, capture only what the glass on this
    /// backdrop can actually reach: the union of their frames, grown by the blur
    /// and refraction reach. Cost is linear in area, and most apps put glass on a
    /// fraction of the screen.
    ///
    /// One bounding box, so glass at both the top and the bottom of a screen
    /// still costs the whole screen, give those two separate backdrops.
    private func autoCaptureRect(in source: UIView) -> CGRect {
        let views = LiquidGlassEngine.shared?.glassViews(using: self) ?? []
        guard !views.isEmpty else { return source.bounds }

        var union = CGRect.null
        var margin: CGFloat = 0
        for view in views {
            union = union.union(view.convert(view.bounds, to: source))
            let configuration = view.configuration
            // Blur reaches furthest (it reads coarse mips), the rim lens only
            // about one thickness. The shader's thickness*6 clamp is a safety
            // net that never binds, and paying area for it is pure waste.
            margin = max(margin, 2 * configuration.blurRadius
                                 + configuration.bevel
                                 + configuration.thickness)
        }
        guard !union.isNull else { return source.bounds }

        // Snap outward to a 32pt grid so a moving glass view does not resize the
        // texture on every frame.
        let grid: CGFloat = 32
        let grown = union.insetBy(dx: -margin, dy: -margin)
        let snapped = CGRect(x: (grown.minX / grid).rounded(.down) * grid,
                             y: (grown.minY / grid).rounded(.down) * grid,
                             width: (grown.width / grid).rounded(.up) * grid,
                             height: (grown.height / grid).rounded(.up) * grid)
        return snapped.intersection(source.bounds).isNull ? source.bounds
             : snapped.intersection(source.bounds)
    }

    private func makeContext(for buffer: CVPixelBuffer) -> CGContext? {
        CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                  width: CVPixelBufferGetWidth(buffer),
                  height: CVPixelBufferGetHeight(buffer),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Parks a `CABackdropLayer` directly above `sourceView`, so it composites
    /// exactly what `sourceView` produces and nothing above it, then rasterizes
    /// that one flat surface.
    private func drawComposited(into context: CGContext, source: UIView) -> Bool {
        guard let host = source.superview else { return false }
        guard let view = compositedView ?? CompositedBackdropView.make() else { return false }
        compositedView = view

        view.frame = source.convert(effectiveRect, to: host)
        // Directly above the source, so it composites exactly what is below the
        // glass. Re-inserting every frame would churn the layer tree.
        if view.superview !== host { host.insertSubview(view, aboveSubview: source) }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        // The CTM is already in sourceView points, and the capture view covers
        // exactly effectiveRect there.
        return view.drawHierarchy(in: effectiveRect, afterScreenUpdates: false)
    }

    private func teardownCompositedView() {
        compositedView?.removeFromSuperview()
        compositedView = nil
    }

    /// True when every sampled pixel is still fully transparent, i.e. nothing was
    /// drawn. A real backdrop is opaque.
    private func isBlank(_ buffer: CVPixelBuffer) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<8 {
            for column in 0..<8 {
                let x = width * (2 * column + 1) / 16
                let y = height * (2 * row + 1) / 16
                if pixels[y * stride + x * 4 + 3] != 0 { return false }
            }
        }
        return true
    }

    private func allocate() -> Bool {
        guard let cache = textureCache else { return false }
        let width = max(8, Int((effectiveRect.width * pixelScale).rounded()))
        let height = max(8, Int((effectiveRect.height * pixelScale).rounded()))

        // Two slots so the CPU can draw the next frame while the GPU still reads
        // the previous one. One slot tears visibly on the sharp rim.
        //
        // IOSurface-backed CVPixelBuffers are the one bridge that is genuinely
        // zero-copy in both directions *and* works in the simulator: a linear
        // MTLTexture over a shared MTLBuffer is rejected there.
        let attributes = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary

        var built: [CaptureSlot] = []
        for _ in 0..<2 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA, attributes,
                                      &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer
            else { return false }

            var bridge: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, cache, pixelBuffer, nil,
                    .bgra8Unorm, width, height, 0, &bridge) == kCVReturnSuccess,
                  let cvTexture = bridge,
                  let texture = CVMetalTextureGetTexture(cvTexture)
            else { return false }

            built.append(CaptureSlot(pixelBuffer: pixelBuffer, bridge: cvTexture, texture: texture))
        }
        slots = built
        slotIndex = 0

        // Frost pyramid: level 0 is half the capture, each further level halves
        // again. Repeated 4-tap tent downsampling converges on a gaussian, so no
        // separate blur pass is needed, and a per-view LOD gives each glass view
        // its own blur radius off one shared pyramid.
        let pyramidWidth = max(1, width / 2)
        let pyramidHeight = max(1, height / 2)
        let levels = Int(floor(log2(Double(max(pyramidWidth, pyramidHeight))))) + 1

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pyramidWidth, height: pyramidHeight, mipmapped: true)
        descriptor.mipmapLevelCount = levels
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let pyramidTexture = device.makeTexture(descriptor: descriptor) else { return false }
        pyramid = pyramidTexture

        // A distinct view per level: a pass may not read and write the same
        // texture object even at different levels.
        pyramidLevelViews = (0..<levels).compactMap {
            pyramidTexture.makeTextureView(pixelFormat: .bgra8Unorm, textureType: .type2D,
                                           levels: $0..<($0 + 1), slices: 0..<1)
        }
        return pyramidLevelViews.count == levels
    }

    /// Maps a blur radius in points onto a mip level of the pyramid.
    func lod(forBlurRadius points: CGFloat) -> Float {
        // Level L has a texel span of 2^(L+1) capture pixels; a tent-chained mip
        // reads like a gaussian of roughly 1.5 texels.
        let radiusInPixels = max(1, points * pixelScale)
        let level = log2(Double(radiusInPixels) / 1.5) - 1
        return Float(max(0, min(level, Double(max(0, pyramidLevelViews.count - 1)))))
    }
}

/// A view whose layer is `CABackdropLayer`, resolved at runtime so the private
/// symbol is never linked. Falls back to a plain layer, which draws nothing and
/// trips the blank probe.
private final class CompositedBackdropView: UIView {

    private static let resolvedLayerClass: AnyClass? = NSClassFromString("CABackdropLayer")

    override class var layerClass: AnyClass { resolvedLayerClass ?? CALayer.self }

    static func make() -> CompositedBackdropView? {
        guard resolvedLayerClass != nil else { return nil }
        let view = CompositedBackdropView(frame: .zero)
        view.isUserInteractionEnabled = false
        // Every backdrop layer carries a group name and it must be unique.
        view.layer.setValue(UUID().uuidString, forKey: "groupName")
        return view
    }
}
