import UIKit
import Metal
import QuartzCore

/// One rounded blob of the material. A `LiquidGlassView` renders its own bounds
/// by default; give it several shapes and set `configuration.mergeRadius` to get
/// the liquid merge.
public struct LiquidGlassShape: Equatable {
    /// In the glass view's coordinate space, points.
    public var rect: CGRect
    /// Negative means "capsule".
    public var cornerRadius: CGFloat
    /// nil wears the view's `configuration.tint`
    public var tint: UIColor?

    public init(rect: CGRect, cornerRadius: CGFloat = -1, tint: UIColor? = nil) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    func resolvedRadius() -> CGFloat {
        cornerRadius < 0 ? min(rect.width, rect.height) / 2 : cornerRadius
    }
}

/// how `setShapes(_:animated:)` moves
public struct LiquidGlassMorph: Equatable {
    public var stiffness: CGFloat
    public var dampingRatio: CGFloat
    /// peak merge radius in points, how thick the neck between shapes gets
    public var bulge: CGFloat
    /// peak scale of the swell, 1 turns it off
    public var pulse: CGFloat
    /// recoil from the partner, as a fraction of the distance between centres, 0 turns it off
    public var kick: CGFloat
    /// 5 plays it five times slower
    public var timeScale: CGFloat

    public init(stiffness: CGFloat = pow(2 * CGFloat.pi / 0.416, 2), dampingRatio: CGFloat = 0.75,
                bulge: CGFloat = 20, pulse: CGFloat = 1.2, kick: CGFloat = 1.0 / 6.0,
                timeScale: CGFloat = 1) {
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
        self.bulge = bulge
        self.pulse = pulse
        self.kick = kick
        self.timeScale = timeScale
    }
}

/// A real-time refracting glass surface.
///
/// ```swift
/// let backdrop = LiquidGlassBackdrop(sourceView: contentView)
/// let bar = LiquidGlassView()
/// bar.backdrop = backdrop
/// bar.cornerRadius = -1                 // capsule
/// view.addSubview(bar)                  // above contentView, not inside it
/// ```
public final class LiquidGlassView: UIView {

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public var configuration = LiquidGlassConfiguration.regular {
        didSet {
            guard configuration != oldValue else { return }
            applyShadow()
            setNeedsGlassRedraw()
        }
    }

    /// What this glass refracts. Without one it degrades to a plain blur.
    public var backdrop: LiquidGlassBackdrop? {
        didSet { updateFallback(); setNeedsGlassRedraw() }
    }

    /// Corner radius in points; negative means capsule. Ignored when `shapes` is set.
    public var cornerRadius: CGFloat = -1 {
        didSet { applyShadow(); setNeedsGlassRedraw() }
    }

    /// Override the rendered geometry. `nil` renders the view's own bounds.
    /// setting it jumps, and cancels a running `setShapes(_:animated:)`
    public var shapes: [LiquidGlassShape]? {
        didSet {
            activeMorph = nil
            applyShadow()
            setNeedsGlassRedraw()
        }
    }

    /// most shapes one view draws, trail droplets included
    public static let maxShapeCount = 12

    public var morph = LiquidGlassMorph()

    /// matched by index. jumps instead with a different count, no window, or reduce motion
    public func setShapes(_ newShapes: [LiquidGlassShape], animated: Bool) {
        let from = resolvedShapes()
        let canAnimate = animated
            && !UIAccessibility.isReduceMotionEnabled
            && window != nil
            && !newShapes.isEmpty
            && from.count == newShapes.count
        shapes = newShapes
        guard canAnimate else { return }
        activeMorph = MorphState(from: from, to: newShapes, bounds: bounds, morph: morph)
        setNeedsGlassRedraw()
    }
    private var activeMorph: MorphState?

    /// the shapes as drawn right now, lay icons over these
    public var displayedShapes: [LiquidGlassShape] { resolvedShapes() }

    /// shrink times pulse of each displayed shape, 1 at rest
    public var displayedScales: [CGSize] {
        activeMorph?.scales ?? Array(repeating: CGSize(width: 1, height: 1), count: resolvedShapes().count)
    }

    /// after every morph step, with the seconds of animation time it covered
    public var onMorphStep: ((CGFloat) -> Void)?

    /// 0 at the start of a morph, 1 once settled
    public var morphProgress: CGFloat { activeMorph?.progress ?? 1 }

    var isMorphing: Bool { activeMorph != nil }

    var morphNeck: CGFloat { activeMorph?.neck ?? 0 }

    var needsGlassRedraw: Bool { needsRedraw }

    // tests flip this, the system setting can't be changed from a test
    var reduceTransparencyOverride: Bool?

    // one grey for the whole view, by appearance
    private var solidPlate: Float {
        guard reduceTransparencyOverride ?? UIAccessibility.isReduceTransparencyEnabled else { return 0 }
        return traitCollection.userInterfaceStyle == .dark ? 0.17 : 0.95
    }

    // the old callback is the one that works on every version this package supports
    @available(iOS, deprecated: 17.0, message: "Superseded by registerForTraitChanges")
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            setNeedsGlassRedraw()
        }
    }

    // both for LiquidGlassBaker
    var rendersRimOverlayOnly = false
    var renderScaleOverride: CGFloat?

    public override var isHidden: Bool {
        didSet { if isHidden != oldValue { setNeedsGlassRedraw() } }
    }

    /// How far the glass lags behind a moving shape, as a fraction of the spring's
    /// natural lag. 0 is rigid; 1 is the water-droplet stretch the system loupe
    /// has. Above ~1.4 it reads as rubber rather than liquid.
    ///
    /// This deforms **shapes inside the view**, not the view itself. The drawable
    /// only covers `bounds`, so a trail behind a moving *view* would be clipped.
    /// Move `shapes` and keep the view where it is.
    ///
    /// Forced to 0 under Reduce Motion, which is what the system does: the
    /// accessibility setting disables the elastic properties of the material.
    public var elasticity: CGFloat = 0 {
        didSet { if elasticity != oldValue { setNeedsGlassRedraw() } }
    }

    private var effectiveElasticity: CGFloat {
        UIAccessibility.isReduceMotionEnabled ? 0 : max(0, elasticity)
    }

    /// The finger's current position, in this view's coordinates, or `nil` when
    /// nothing is pulling. Feed it from your own gesture: the point at `.began`
    /// is taken as the grab, and travel from there stretches the shape under it.
    ///
    /// The shape stays put and elongates toward you, far edge anchored, near
    /// edge following, so a circle becomes an oval and a bar gets taller. Capped
    /// at 30% of the shape's short side.
    ///
    /// Driving it off distance from the shape's *edge* instead of from the grab
    /// point is the obvious-looking mistake: a 76pt button then does nothing at
    /// all until the finger is 38pt clear of it.
    ///
    /// Same canvas rule as `elasticity`: a 64pt-tall bar cannot draw a stretch
    /// above itself. Give the view the room and put the shape at its edge.
    public var pullPoint: CGPoint? {
        didSet {
            // Remember where the gesture grabbed: the stretch is driven by travel
            // from that point, so it responds to the first pixel of movement.
            if oldValue == nil, pullPoint != nil { pullOrigin = pullPoint }
            setNeedsGlassRedraw()
        }
    }

    /// The deformation, as the transform a subview needs to ride it: the
    /// centroid's travel plus the shape's change in proportions, so a glyph both
    /// follows the finger and narrows with the glass around it.
    private var contentTransform: CGAffineTransform = .identity

    private var trailCenters: [CGPoint] = []
    private var trailVelocities: [CGVector] = []
    private var pullCenter: CGPoint?
    private var pullOrigin: CGPoint?
    private var pullVelocity = CGVector.zero

    private var needsRedraw = true
    private var fallbackView: UIVisualEffectView?

    // MARK: Lifecycle

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        layer.masksToBounds = false
        metalLayer.device = LiquidGlassEngine.shared?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        applyShadow()
        updateFallback()
        // selector based, so it goes with the view
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityDidChange),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @objc private func accessibilityDidChange() {
        setNeedsGlassRedraw()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window = window {
            metalLayer.contentsScale = window.screen.scale
            LiquidGlassEngine.shared?.register(self)
            setNeedsGlassRedraw()
        } else {
            LiquidGlassEngine.shared?.unregister(self)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = renderScaleOverride ?? window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        fallbackView?.frame = bounds
        applyShadow()
        setNeedsGlassRedraw()
    }

    public func setNeedsGlassRedraw() {
        needsRedraw = true
        LiquidGlassEngine.shared?.wake()
    }

    // MARK: Shape

    private func resolvedShapes() -> [LiquidGlassShape] {
        let target: [LiquidGlassShape]
        if let shapes = shapes, !shapes.isEmpty {
            target = shapes
        } else {
            target = [LiquidGlassShape(rect: bounds, cornerRadius: cornerRadius)]
        }
        guard let active = activeMorph, active.to.count == target.count else { return target }
        return active.shapes
    }

    private func shapePath() -> UIBezierPath {
        let path = UIBezierPath()
        for shape in resolvedShapes() {
            path.append(UIBezierPath(roundedRect: shape.rect, cornerRadius: shape.resolvedRadius()))
        }
        return path
    }

    /// Touches outside the glass shape fall through to whatever is underneath.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        shapePath().contains(point)
    }

    private func updateShadowPath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        layer.shadowPath = shapePath().cgPath
    }

    private func applyShadow() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        updateShadowPath()
        layer.shadowOpacity = Float(configuration.shadowOpacity)
        layer.shadowRadius = configuration.shadowRadius
        layer.shadowOffset = configuration.shadowOffset
        layer.shadowColor = UIColor.black.cgColor
        fallbackView?.layer.cornerRadius = resolvedShapes().first?.resolvedRadius() ?? 0
    }

    /// Without Metal (or with a broken shader build) show a plain blur rather
    /// than a hole in the UI.
    private func updateFallback() {
        let needsFallback = LiquidGlassEngine.shared == nil
        if needsFallback, fallbackView == nil {
            let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            effect.frame = bounds
            effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            effect.layer.masksToBounds = true
            addSubview(effect)
            fallbackView = effect
        } else if !needsFallback, let existing = fallbackView {
            existing.removeFromSuperview()
            fallbackView = nil
        }
    }

    // MARK: Interaction

    /// Springs on the elastic deformations, stepped by the engine.
    func stepAnimation(duration: CFTimeInterval) {
        let dt = CGFloat(min(max(duration, 1.0 / 240.0), 1.0 / 30.0))
        stepMorph(dt)
        stepTrail(dt)
        stepPull(dt)
    }

    private func stepMorph(_ frameTime: CGFloat) {
        guard var active = activeMorph else { return }
        let dt = frameTime / max(0.05, morph.timeScale)
        active.step(dt)
        activeMorph = active.isSettled ? nil : active
        needsRedraw = true
        updateShadowPath()
        onMorphStep?(dt)
    }

    /// Lags the finger while pulling, springs back to the grab point on release.
    private func stepPull(_ dt: CGFloat) {
        guard effectiveElasticity > 0 else {
            if pullCenter != nil { pullCenter = nil; pullOrigin = nil; needsRedraw = true }
            return
        }
        guard var center = pullCenter ?? pullPoint, let origin = pullOrigin else { return }
        // Released: back to where the gesture started, where the stretch is zero.
        let target = pullPoint ?? origin

        // Alive while you drag, critically damped on the way home: a retract that
        // overshoots reads as a glitch, not as liquid.
        let stiffness: CGFloat = 300
        let damping = 2 * sqrt(stiffness) * (pullPoint == nil ? 1.0 : 0.8)
        pullVelocity.dx += (-stiffness * (center.x - target.x) - damping * pullVelocity.dx) * dt
        pullVelocity.dy += (-stiffness * (center.y - target.y) - damping * pullVelocity.dy) * dt
        center.x += pullVelocity.dx * dt
        center.y += pullVelocity.dy * dt
        pullCenter = center
        needsRedraw = true

        // Back at the grab point, where the stretch is already zero.
        if pullPoint == nil,
           abs(center.x - target.x) < 0.5, abs(center.y - target.y) < 0.5 {
            pullCenter = nil
            pullOrigin = nil
            pullVelocity = .zero
        }
    }

    private func nearest(to point: CGPoint, among shapes: [LiquidGlassShape]) -> LiquidGlassShape? {
        shapes.min { a, b in
            hypot(a.rect.midX - point.x, a.rect.midY - point.y)
                < hypot(b.rect.midX - point.x, b.rect.midY - point.y)
        }
    }

    /// How far a droplet may get from its shape's surface, scaled by `elasticity`.
    private func maxReach(from shape: LiquidGlassShape) -> CGFloat {
        min(shape.rect.width, shape.rect.height) / 2 * effectiveElasticity
    }

    /// The merge radius needed to bridge a given gap, and nothing more.
    ///
    /// This must scale with the *current* gap, never be a constant sized for the
    /// worst case. The quadratic smooth-min pulls coincident shapes together by
    /// k/4, so a merge radius held wide while the droplet is already home leaves
    /// the whole bar visibly inflated, and then pops it back the frame the
    /// droplet is dropped. Proportional means it reaches zero exactly when the
    /// droplet does, and nothing steps.
    private func bridging(gap: CGFloat) -> CGFloat {
        max(0, gap) * 3   // needs > 2*gap to bridge; 3 leaves the neck thick
    }

    /// How far a shape may be stretched toward a pull, scaled by `elasticity`.
    /// Deliberately small: this reads as a material giving slightly, and past
    /// roughly a fifth of the short side it starts reading as the control
    /// growing instead.
    private func maxStretch(of shape: LiquidGlassShape) -> CGFloat {
        min(shape.rect.width, shape.rect.height) * 0.14 * effectiveElasticity
    }

    /// Stretching the shape itself toward the finger: the whole bar lifts a little,
    /// the whole button sags a little.
    ///
    /// The earlier model drew a droplet out on a neck. That is what a free blob
    /// does, but a bar is not a blob: pulling a blister off it reads as a
    /// separate object, however well the neck is bridged. Deform the one shape.
    private func stretched(_ shapes: [LiquidGlassShape]) -> [LiquidGlassShape] {
        guard effectiveElasticity > 0, let center = pullCenter, let origin = pullOrigin,
              let home = nearest(to: origin, among: shapes),
              let index = shapes.firstIndex(where: { $0.rect == home.rect })
        else { contentTransform = .identity; return shapes }

        // Measured from where the finger grabbed, not from the shape's edge.
        // Off the edge, a 76pt button would not move at all until the finger had
        // traveled 38pt clear of it.
        var pull = CGVector(dx: center.x - origin.x, dy: center.y - origin.y)
        let distance = hypot(pull.dx, pull.dy)
        let limit = maxStretch(of: home)
        guard distance > 0.01, limit > 0.5 else { contentTransform = .identity; return shapes }
        // Ease out: the first points of travel move it most, then it stiffens,
        // the way a membrane does.
        let amount = limit * (1 - exp(-distance / limit))
        pull.dx *= amount / distance
        pull.dy *= amount / distance

        // The far edge holds, the near one travels. `follow` above zero lets the
        // whole body drift along instead, which reads as the control sliding
        // rather than as the material giving.
        let follow: CGFloat = 0
        var rect = home.rect
        rect.origin.y += pull.dy > 0 ? pull.dy * follow : pull.dy
        rect.size.height += abs(pull.dy) * (1 - follow)
        rect.origin.x += pull.dx > 0 ? pull.dx * follow : pull.dx
        rect.size.width += abs(pull.dx) * (1 - follow)

        // Thin across the pull. Without this the shape only ever gets bigger,
        // which reads as the button inflating rather than as an oval being drawn
        // out of a circle.
        let squash: CGFloat = 0.7
        let thinX = min(abs(pull.dy) * squash, home.rect.width * 0.2)
        let thinY = min(abs(pull.dx) * squash, home.rect.height * 0.2)
        rect = rect.insetBy(dx: thinX / 2, dy: thinY / 2)

        rect = rect.intersection(bounds.insetBy(dx: -0.5, dy: -0.5))

        contentTransform = CGAffineTransform(translationX: rect.midX - home.rect.midX,
                                             y: rect.midY - home.rect.midY)
            .scaledBy(x: rect.width / home.rect.width, y: rect.height / home.rect.height)

        var result = shapes
        // A capsule stays a capsule: a circle stretches into an oval and a bar
        // into a longer bar, with no corner-shape discontinuity the moment the
        // stretch starts. Anything with an explicit radius keeps it.
        result[index] = LiquidGlassShape(rect: rect,
                                         cornerRadius: home.cornerRadius < 0 ? -1 : home.resolvedRadius(),
                                         tint: home.tint)
        return result
    }

    /// Rides the view's own subviews along with the deformation. A transform,
    /// not a frame change, so Auto Layout underneath is untouched.
    private func applyContentOffset() {
        for subview in subviews where subview !== fallbackView {
            if subview.transform != contentTransform { subview.transform = contentTransform }
        }
    }

    /// A mass on a spring per shape, chasing that shape's center. Slightly
    /// under-damped, so a flick settles with a wobble instead of a dead stop.
    private func stepTrail(_ dt: CGFloat) {
        let shapes = resolvedShapes()
        guard effectiveElasticity > 0 else {
            if !trailCenters.isEmpty {
                trailCenters.removeAll()
                trailVelocities.removeAll()
                needsRedraw = true
            }
            return
        }
        if trailCenters.count != shapes.count {
            trailCenters = shapes.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
            trailVelocities = Array(repeating: CGVector.zero, count: shapes.count)
            return
        }

        let stiffness: CGFloat = 260
        let damping = 2 * sqrt(stiffness) * 0.78
        for index in shapes.indices {
            let target = CGPoint(x: shapes[index].rect.midX, y: shapes[index].rect.midY)
            var velocity = trailVelocities[index]
            var center = trailCenters[index]
            velocity.dx += (-stiffness * (center.x - target.x) - damping * velocity.dx) * dt
            velocity.dy += (-stiffness * (center.y - target.y) - damping * velocity.dy) * dt
            center.x += velocity.dx * dt
            center.y += velocity.dy * dt
            trailVelocities[index] = velocity
            trailCenters[index] = center
            if abs(center.x - target.x) > 0.05 || abs(center.y - target.y) > 0.05
                || abs(velocity.dx) > 0.05 || abs(velocity.dy) > 0.05 {
                needsRedraw = true
            }
        }
    }

    /// The trailing droplets, in shape space. Empty when nothing is moving, so a
    /// resting view costs exactly what it did before.
    private func trailShapes(for shapes: [LiquidGlassShape]) -> ([LiquidGlassShape], CGFloat) {
        guard effectiveElasticity > 0, trailCenters.count == shapes.count else { return ([], 0) }
        var trails: [LiquidGlassShape] = []
        var merge: CGFloat = 0
        for (index, shape) in shapes.enumerated() {
            let center = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
            var lag = CGVector(dx: (trailCenters[index].x - center.x) * effectiveElasticity,
                               dy: (trailCenters[index].y - center.y) * effectiveElasticity)
            var distance = hypot(lag.dx, lag.dy)
            guard distance > 0.5 else { continue }

            // A droplet cannot stretch without limit: surface tension caps the
            // neck and then it would pinch off. Cap the lag and taper instead.
            let radius = min(shape.rect.width, shape.rect.height) / 2
            let maxLag = radius * 1.2
            if distance > maxLag {
                lag.dx *= maxLag / distance
                lag.dy *= maxLag / distance
                distance = maxLag
            }
            let taper = 1 - 0.4 * (distance / maxLag)
            let size = CGSize(width: shape.rect.width * taper, height: shape.rect.height * taper)
            trails.append(LiquidGlassShape(
                rect: CGRect(x: center.x + lag.dx - size.width / 2,
                             y: center.y + lag.dy - size.height / 2,
                             width: size.width, height: size.height),
                cornerRadius: shape.cornerRadius < 0 ? -1 : shape.cornerRadius * taper,
                tint: shape.tint))
            merge = max(merge, bridging(gap: distance / 2))
        }
        return (trails, merge)
    }

    // MARK: Render

    /// Returns true if a drawable was presented.
    func encode(into commandBuffer: MTLCommandBuffer, light: SIMD3<Float>) -> Bool {
        guard needsRedraw, let drawable = metalLayer.nextDrawable() else { return false }
        guard encodeGlass(into: commandBuffer, target: drawable.texture, light: light) else { return false }
        needsRedraw = false
        commandBuffer.present(drawable)
        return true
    }

    /// The whole render, independent of where it lands. The tests point it at an
    /// offscreen texture so the shader and the uniform layout can be checked
    /// without a window.
    @discardableResult
    func encodeGlass(into commandBuffer: MTLCommandBuffer,
                     target: MTLTexture,
                     light: SIMD3<Float>) -> Bool {
        guard let engine = LiquidGlassEngine.shared,
              let backdrop = backdrop,
              let source = backdrop.sourceView,
              let sharp = backdrop.sharpTexture,
              let pyramid = backdrop.pyramid,
              bounds.width > 1, bounds.height > 1
        else { return false }

        let captureSize = backdrop.captureSizeInPoints
        guard captureSize.width > 0, captureSize.height > 0 else { return false }

        let scale = Float(metalLayer.contentsScale)
        let origin = convert(CGPoint.zero, to: source)
        var uniforms = LGUniforms()
        uniforms.viewSize = SIMD2(Float(bounds.width) * scale, Float(bounds.height) * scale)
        uniforms.backdropOrigin = SIMD2(Float(origin.x - backdrop.effectiveRect.origin.x),
                                        Float(origin.y - backdrop.effectiveRect.origin.y))
        uniforms.backdropInvSize = SIMD2(1 / Float(captureSize.width), 1 / Float(captureSize.height))
        uniforms.scale = scale

        let bevel = Float(configuration.bevel) * scale
        uniforms.lightDirBevel = SIMD4(light.x, light.y, light.z, bevel)
        uniforms.thickness = Float(configuration.thickness) * scale
        uniforms.ior = Float(configuration.refractiveIndex)
        uniforms.chroma = Float(configuration.chromaticAberration)
        uniforms.frost = Float(configuration.frost)
        uniforms.saturation = Float(configuration.saturation)
        uniforms.adaptivity = Float(configuration.adaptivity)
        uniforms.darkVeil = Float(configuration.darkVeil)
        uniforms.lightVeil = Float(configuration.lightVeil)
        uniforms.specular = Float(configuration.specular)
        uniforms.shininess = Float(configuration.shininess)
        uniforms.fresnel = Float(configuration.fresnel)
        uniforms.innerShadow = Float(configuration.innerShadow)
        uniforms.mergeRadius = Float(configuration.mergeRadius) * scale
        uniforms.blurLOD = backdrop.lod(forBlurRadius: configuration.blurRadius)
        uniforms.solid = solidPlate
        uniforms.overlay = rendersRimOverlayOnly ? 1 : 0

        // a shape without its own tint wears the view's
        func packedTint(_ color: UIColor?) -> SIMD4<Float> {
            guard let color = color else { return SIMD4(0, 0, 0, 0) }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        }
        uniforms.tint = packedTint(configuration.tint)

        // Leaders first, then their trailing droplets, so the 12-shape budget
        // never drops a real shape in favour of a trail.
        // Trail first, off the undeformed shapes. Feeding it the stretched ones
        // makes a stretch look like movement: pull down, the center shifts down,
        // and the trail emits a catching-up twin *above*, the opposite side from
        // the one being pulled.
        let base = resolvedShapes()
        let (extras, required) = trailShapes(for: base)
        let leaders = stretched(base)
        applyContentOffset()
        let emitted = Array((leaders + extras).prefix(Self.maxShapeCount))

        // Deformation is only liquid if it bridges, but only by as much as the
        // current gap needs, so the radius decays to nothing along with the
        // droplet instead of stepping when it is dropped.
        uniforms.mergeRadius = max(uniforms.mergeRadius, Float(required) * scale)
        // zero at both ends, so nothing stays merged or inflated once it lands
        uniforms.mergeRadius = max(uniforms.mergeRadius, Float(morphNeck) * scale)

        var shapes = emitted.enumerated().map { index, shape -> LGShape in
            var packed = LGShape()
            let center = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
            packed.center = SIMD2(Float(center.x) * scale, Float(center.y) * scale)
            packed.halfSize = SIMD2(Float(shape.rect.width / 2) * scale,
                                    Float(shape.rect.height / 2) * scale)
            packed.cornerRadius = Float(shape.resolvedRadius()) * scale
            // Continuous corners are a property of rounded *rectangles*. A capsule
            // ends in a true semicircle, so a circle asked to use the p-norm at
            // 4.2 comes out a rounded square, which is what a round button was
            // rendering as.
            let isCapsule = shape.resolvedRadius() >= min(shape.rect.width, shape.rect.height) / 2 - 0.5
            packed.cornerExponent = isCapsule ? 2 : Float(configuration.cornerExponent)
            packed.tint = shape.tint.map { packedTint($0) } ?? uniforms.tint
            return packed
        }
        uniforms.shapeCount = Float(shapes.count)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }

        encoder.setRenderPipelineState(engine.glassPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LGUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&shapes, length: MemoryLayout<LGShape>.stride * shapes.count, index: 1)
        encoder.setFragmentTexture(sharp, index: 0)
        encoder.setFragmentTexture(pyramid, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}

