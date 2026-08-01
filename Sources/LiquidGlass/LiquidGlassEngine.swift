import UIKit
import Metal
import CoreMotion
import simd

/// One display link, one command queue, one motion manager for every piece of
/// glass in the process. Per-view display links would fight each other and the
/// backdrop would be captured N times per frame.
public final class LiquidGlassEngine {

    /// `nil` only where Metal or the shader library is unavailable. No device
    /// that can run iOS 15 lacks Metal, but a broken shader build hits this too,
    /// and `LiquidGlassView` then falls back to `UIVisualEffectView`.
    public static let shared: LiquidGlassEngine? = LiquidGlassEngine()

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let downsamplePipeline: MTLRenderPipelineState
    let glassPipeline: MTLRenderPipelineState

    private var views: [Weak] = []
    private var displayLink: CADisplayLink?
    private let inFlight = DispatchSemaphore(value: 2)   // matches the 2 capture slots
    private let motion = CMMotionManager()
    private var lightDirection = SIMD3<Float>(-0.45, -0.72, 0.53)

    /// Frames per second measured over the last second.
    public private(set) var framesPerSecond: Double = 0
    private var frameCount = 0
    private var frameWindowStart: CFTimeInterval = 0

    private struct Weak { weak var view: LiquidGlassView? }

    private init?() {
        assert(MemoryLayout<LGUniforms>.stride == 128, "LGUniforms drifted from Shaders.metal")
        assert(MemoryLayout<LGShape>.stride == 32, "LGShape drifted from Shaders.metal")

        // Swift Package Manager compiles the .metal file into the package's own
        // resource bundle; built straight into an app it lands in the default one.
        #if SWIFT_PACKAGE
        let metalLibrary = try? MTLCreateSystemDefaultDevice()?.makeDefaultLibrary(bundle: .module)
        #else
        let metalLibrary = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
        #endif

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = metalLibrary ?? device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "lg_vertex"),
              let downsampleFunction = library.makeFunction(name: "lg_downsample"),
              let glassFunction = library.makeFunction(name: "lg_glass")
        else { return nil }

        let downsampleDescriptor = MTLRenderPipelineDescriptor()
        downsampleDescriptor.vertexFunction = vertexFunction
        downsampleDescriptor.fragmentFunction = downsampleFunction
        downsampleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let glassDescriptor = MTLRenderPipelineDescriptor()
        glassDescriptor.vertexFunction = vertexFunction
        glassDescriptor.fragmentFunction = glassFunction
        let attachment = glassDescriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true          // shader outputs premultiplied
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let downsample = try? device.makeRenderPipelineState(descriptor: downsampleDescriptor),
              let glass = try? device.makeRenderPipelineState(descriptor: glassDescriptor)
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.downsamplePipeline = downsample
        self.glassPipeline = glass
    }

    // MARK: Registry

    func register(_ view: LiquidGlassView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(Weak(view: view))
        startIfNeeded()
    }

    /// Visible glass drawing off this backdrop, used to size the capture.
    func glassViews(using backdrop: LiquidGlassBackdrop) -> [LiquidGlassView] {
        views.compactMap { $0.view }
            .filter { $0.backdrop === backdrop && $0.window != nil && !$0.isHidden }
    }

    func unregister(_ view: LiquidGlassView) {
        views.removeAll { $0.view == nil || $0.view === view }
        if views.isEmpty { stop() }
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        frameWindowStart = CACurrentMediaTime()
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        motion.stopDeviceMotionUpdates()
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        views.removeAll { $0.view == nil }
        let live = views.compactMap { $0.view }.filter { $0.window != nil && !$0.isHidden }
        guard !live.isEmpty else { return }

        // Never block the main thread waiting on the GPU: drop the frame instead.
        guard inFlight.wait(timeout: .now()) == .success else { return }

        let previousLight = lightDirection
        updateLight(for: live)
        if simd_distance(previousLight, lightDirection) > 0.0004 {
            for view in live { view.setNeedsGlassRedraw() }
        }
        for view in live { view.stepAnimation(duration: link.duration) }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        // Capture + rebuild each distinct backdrop exactly once per frame, then
        // dirty every view reading it.
        var seen = Set<ObjectIdentifier>()
        var refreshed = Set<ObjectIdentifier>()
        for view in live {
            guard let backdrop = view.backdrop else { continue }
            let key = ObjectIdentifier(backdrop)
            guard seen.insert(key).inserted else { continue }
            if backdrop.captureIfNeeded() {
                encodePyramid(for: backdrop, into: commandBuffer)
                refreshed.insert(key)
            }
        }
        for view in live {
            guard let backdrop = view.backdrop else { continue }
            if refreshed.contains(ObjectIdentifier(backdrop)) { view.setNeedsGlassRedraw() }
        }

        var presented = false
        for view in live where view.encode(into: commandBuffer, light: lightDirection) {
            presented = true
        }

        commandBuffer.addCompletedHandler { [semaphore = inFlight] _ in semaphore.signal() }
        commandBuffer.commit()

        if presented { countFrame() }
    }

    private func countFrame() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - frameWindowStart
        if elapsed >= 1 {
            framesPerSecond = Double(frameCount) / elapsed
            frameCount = 0
            frameWindowStart = now
        }
    }

    /// Level 0 of the pyramid comes from the capture, every further level from
    /// the one above it.
    func encodePyramid(for backdrop: LiquidGlassBackdrop, into commandBuffer: MTLCommandBuffer) {
        guard let sharp = backdrop.sharpTexture, !backdrop.pyramidLevelViews.isEmpty else { return }

        for level in backdrop.pyramidLevelViews.indices {
            let source: MTLTexture = level == 0 ? sharp : backdrop.pyramidLevelViews[level - 1]
            let destination = backdrop.pyramidLevelViews[level]

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }

            // Tent taps sit half a source texel out, which is where the bilinear
            // filter averages 2x2, so four taps cover a 4x4 neighborhood.
            var texel = SIMD2<Float>(0.5 / Float(source.width), 0.5 / Float(source.height))
            encoder.setRenderPipelineState(downsamplePipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    // MARK: Light

    private func updateLight(for views: [LiquidGlassView]) {
        let wantsMotion = views.contains { $0.configuration.motionResponsive }
        let fallback = views.first?.configuration.staticLightDirection ?? SIMD3<Float>(-0.45, -0.72, 0.53)

        guard wantsMotion, motion.isDeviceMotionAvailable else {
            if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
            lightDirection = simd_normalize(fallback)
            return
        }
        if !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates()
        }
        guard let gravity = motion.deviceMotion?.gravity else {
            lightDirection = simd_normalize(fallback)
            return
        }

        // World "up" in device axes is -gravity. Screen space has +y pointing
        // down, so the y component flips sign again and cancels out. Held
        // upright this lands at (0, -1, k): highlight on the top rim.
        let target = simd_normalize(SIMD3<Float>(Float(-gravity.x), Float(gravity.y), 0.55))
        lightDirection = simd_normalize(simd_mix(lightDirection, target, SIMD3<Float>(repeating: 0.12)))
    }
}
