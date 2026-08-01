import XCTest
import Metal
@testable import LiquidGlass

/// The two properties that cannot be checked by looking at the screen.
///
/// A wrong `LGUniforms` layout, a flipped UV, a bad backdrop-origin conversion or
/// a broken blend mode all still produce something glass-ish; you notice weeks
/// later that the refraction samples the wrong part of the screen. Turning the
/// optics off makes the correct answer exact, so those bugs become assertable.
final class LiquidGlassTests: XCTestCase {

    /// Swift and Metal Shading Language agree on the uniform layout only because
    /// every scalar sits at its natural offset. Pin it.
    func testUniformLayoutMatchesShader() {
        XCTAssertEqual(MemoryLayout<LGUniforms>.stride, 128)
        XCTAssertEqual(MemoryLayout<LGShape>.stride, 32)
    }

    /// With refraction, frost, tint, saturation and light all neutralized, the
    /// glass must return the backdrop pixel that sits directly underneath it.
    /// Any error in the view -> backdrop coordinate mapping shows up as a
    /// different quadrant's color.
    ///
    /// Run against both capture modes. Caveat worth knowing: `drawHierarchy`
    /// returns false for *any* view under XCTest, verified with a plain opaque
    /// control view, so in this harness the composited mode always falls back
    /// and only the public path is really covered. What this does pin is that the
    /// fallback itself produces correct pixels. The composited path proper has to
    /// be checked in a running app, against `activeCaptureMode`.
    func testNeutralGlassIsPixelExactPassThroughInEveryCaptureMode() throws {
        for mode in [LiquidGlassCaptureMode.viewTree, .compositedBackdrop] {
            let (engine, glass, backdrop, window) = try makeFixture(mode: mode)
            defer { window.isHidden = true }

            let scale = glass.layer.contentsScale
            let target = try makeTarget(engine: engine,
                                        width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
            print("CAPTURE MODE requested \(mode) -> active \(backdrop.activeCaptureMode)")

            // Glass sits at (40,40) in the source, so its (30,30) is the source's
            // (70,70), well inside the red top-left quadrant.
            let pixel = readPixel(target, x: Int(30 * scale), y: Int(30 * scale))
            XCTAssertEqual(pixel.alpha, 255, "\(mode): inside the shape must be opaque")
            XCTAssertEqual(Int(pixel.red), 255, accuracy: 4, "\(mode) red")
            XCTAssertEqual(Int(pixel.green), 0, accuracy: 4, "\(mode) green")
            XCTAssertEqual(Int(pixel.blue), 0, accuracy: 4, "\(mode) blue")

            // And the opposite corner, which is what a vertical flip would swap in.
            let lower = readPixel(target, x: Int(30 * scale), y: Int(90 * scale))
            XCTAssertEqual(Int(lower.blue), 255, accuracy: 4, "\(mode): bottom-left must be blue")
        }
    }

    /// Outside the rounded shape the fragment must be fully transparent, not a
    /// clipped square: the corner is cut by the SDF, not by a layer mask.
    func testOutsideTheRoundedCornerIsTransparent() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.cornerRadius = 40

        let scale = glass.layer.contentsScale
        let target = try makeTarget(engine: engine,
                                    width: Int(glass.bounds.width * scale),
                                    height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)

        let corner = readPixel(target, x: 1, y: 1)
        XCTAssertEqual(corner.alpha, 0, "the corner is outside a 40pt radius")

        let center = readPixel(target, x: Int(60 * scale), y: Int(60 * scale))
        XCTAssertEqual(center.alpha, 255, "the center is inside")
    }

    /// The liquid merge: the gap between two shapes must be empty at
    /// `mergeRadius = 0` and filled once the radius is wide enough for the
    /// smooth-min to bridge it. Nothing else may move: the shapes themselves stay
    /// exactly where they were put.
    func testMergeRadiusBridgesTheGapWithoutMovingTheShapes() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.frame = CGRect(x: 40, y: 40, width: 120, height: 120)
        // Two 40pt circles 40pt apart inside the view.
        glass.shapes = [
            LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40)),
            LiquidGlassShape(rect: CGRect(x: 80, y: 40, width: 40, height: 40)),
        ]
        glass.layoutIfNeeded()

        let scale = glass.layer.contentsScale
        let midpoint = (x: Int(60 * scale), y: Int(60 * scale))
        let leftCenter = (x: Int(20 * scale), y: Int(60 * scale))

        var configuration = glass.configuration
        configuration.mergeRadius = 0
        glass.configuration = configuration
        var target = try makeTarget(engine: engine,
                                    width: Int(glass.bounds.width * scale),
                                    height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
        XCTAssertEqual(readPixel(target, x: midpoint.x, y: midpoint.y).alpha, 0,
                       "with no merge radius the gap must stay empty")
        XCTAssertEqual(readPixel(target, x: leftCenter.x, y: leftCenter.y).alpha, 255)

        configuration.mergeRadius = 120   // a = b = 20pt at the midpoint, k/4 = 30pt
        glass.configuration = configuration
        target = try makeTarget(engine: engine,
                                width: Int(glass.bounds.width * scale),
                                height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
        XCTAssertEqual(readPixel(target, x: midpoint.x, y: midpoint.y).alpha, 255,
                       "a wide merge radius must bridge the gap")
        XCTAssertEqual(readPixel(target, x: leftCenter.x, y: leftCenter.y).alpha, 255,
                       "merging must not move or hollow out the shapes themselves")
    }

    /// Elasticity: a moving shape must leave a droplet behind it, and that
    /// droplet must be gone once the spring settles. The probe point is chosen
    /// outside the leader's own radius, so only the trail can light it up, with
    /// `elasticity = 0` the very same frame leaves it transparent.
    func testElasticityLeavesADropletTrailOnlyWhileMoving() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.frame = CGRect(x: 40, y: 40, width: 120, height: 120)
        glass.layoutIfNeeded()
        let scale = glass.layer.contentsScale

        // 40pt shape, so radius 20 and the leader alone covers x in 70...110.
        // The trail is capped at 1.2 radii of lag and tapers, covering 54...78.
        let start = CGRect(x: 10, y: 40, width: 40, height: 40)
        let moved = CGRect(x: 70, y: 40, width: 40, height: 40)
        let probe = (x: Int(60 * scale), y: Int(60 * scale))

        func alphaAfterJump(elasticity: CGFloat, settleFrames: Int) throws -> UInt8 {
            glass.elasticity = elasticity
            glass.shapes = [LiquidGlassShape(rect: start)]
            glass.stepAnimation(duration: 1.0 / 60)      // seeds the trail at rest
            glass.shapes = [LiquidGlassShape(rect: moved)]
            for _ in 0...settleFrames { glass.stepAnimation(duration: 1.0 / 60) }

            let target = try makeTarget(engine: engine,
                                        width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
            return readPixel(target, x: probe.x, y: probe.y).alpha
        }

        XCTAssertEqual(try alphaAfterJump(elasticity: 1, settleFrames: 0), 255,
                       "a shape that just jumped must still have its droplet behind it")
        XCTAssertEqual(try alphaAfterJump(elasticity: 1, settleFrames: 240), 0,
                       "once the spring settles the droplet must be reabsorbed")
        XCTAssertEqual(try alphaAfterJump(elasticity: 0, settleFrames: 0), 0,
                       "with elasticity off the same frame leaves nothing behind")
    }

    /// A pull stretches the bar itself toward the finger and lets it settle
    /// back. The probe sits just above the bar's resting top edge, so only the
    /// stretch can light it, with `elasticity = 0` the identical frame is empty.
    func testPullStretchesTheBarItselfAndItSettlesBack() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.frame = CGRect(x: 20, y: 20, width: 120, height: 160)
        // A bar across the bottom, with head-room above it for the bulge.
        // Room left below the bar on purpose: the far side must stay untouched.
        glass.shapes = [LiquidGlassShape(rect: CGRect(x: 0, y: 100, width: 120, height: 40))]
        glass.layoutIfNeeded()
        let scale = glass.layer.contentsScale
        // A 120x40 bar stretches by at most min(w,h) * 0.16 = 6.4pt, so its top
        // edge travels from 100 up to 93.6. Probe at 97: inside the stretch,
        // never covered by the resting bar.
        let probe = (x: Int(60 * scale), y: Int(97 * scale))
        // Below the bar's resting edge, pulling *up* must leave this empty.
        let farSide = (x: Int(60 * scale), y: Int(152 * scale))

        var lastFarSide: UInt8 = 0
        func alpha(elasticity: CGFloat, pulling: Bool, settleFrames: Int) throws -> UInt8 {
            glass.elasticity = elasticity
            // Grab on the bar, then drag: the stretch is driven by travel from the
            // grab point, so a gesture that starts and ends in one place does
            // nothing at all, which is what a real button was doing on device.
            glass.pullPoint = CGPoint(x: 60, y: 130)
            glass.stepAnimation(duration: 1.0 / 60)
            glass.pullPoint = CGPoint(x: 60, y: 40)
            glass.stepAnimation(duration: 1.0 / 60)
            if !pulling { glass.pullPoint = nil }
            for _ in 0...settleFrames { glass.stepAnimation(duration: 1.0 / 60) }

            let target = try makeTarget(engine: engine,
                                        width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
            lastFarSide = readPixel(target, x: farSide.x, y: farSide.y).alpha
            return readPixel(target, x: probe.x, y: probe.y).alpha
        }

        XCTAssertEqual(try alpha(elasticity: 1, pulling: true, settleFrames: 40), 255,
                       "while pulling, the bar itself must reach above its resting edge")
        XCTAssertEqual(lastFarSide, 0,
                       "only the pulled side may move, nothing appears on the far side")
        XCTAssertEqual(try alpha(elasticity: 1, pulling: false, settleFrames: 240), 0,
                       "on release it must settle back to its resting edge")
        XCTAssertEqual(try alpha(elasticity: 0, pulling: true, settleFrames: 40), 0,
                       "with elasticity off a pull does nothing at all")
    }

    /// A button's glyph must ride the deformation. Without it the shape slides
    /// out from under its own icon, which is exactly what you notice first.
    func testContentRidesAlongWithTheStretch() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.frame = CGRect(x: 20, y: 20, width: 160, height: 160)
        glass.shapes = [LiquidGlassShape(rect: CGRect(x: 50, y: 50, width: 60, height: 60))]
        let glyph = UIView(frame: CGRect(x: 70, y: 70, width: 20, height: 20))
        glass.addSubview(glyph)
        glass.elasticity = 1
        glass.layoutIfNeeded()

        func render() throws {
            let scale = glass.layer.contentsScale
            let target = try makeTarget(engine: engine,
                                        width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try self.render(engine: engine, glass: glass, backdrop: backdrop, target: target)
        }

        XCTAssertEqual(glyph.transform, .identity, "at rest the glyph must not be moved")

        glass.pullPoint = CGPoint(x: 80, y: 80)
        glass.stepAnimation(duration: 1.0 / 60)
        glass.pullPoint = CGPoint(x: 80, y: 150)          // drag downwards
        for _ in 0..<40 { glass.stepAnimation(duration: 1.0 / 60) }
        try render()
        XCTAssertGreaterThan(glyph.transform.ty, 1, "pulling down must carry the glyph down")
        XCTAssertEqual(glyph.transform.tx, 0, accuracy: 0.01, "a vertical pull must not shift it sideways")
        XCTAssertLessThan(glyph.transform.a, 0.99, "and narrow it, the way the glass around it narrows")
        XCTAssertGreaterThan(glyph.transform.d, 1.01, "while lengthening it along the pull")

        glass.pullPoint = nil
        for _ in 0..<300 { glass.stepAnimation(duration: 1.0 / 60) }
        try render()
        XCTAssertEqual(glyph.transform, .identity, "it must come all the way back")
    }

    // MARK: Fixture

    /// The container lives in a real key window: `CABackdropLayer` has nothing to
    /// composite off a detached view tree, so a detached fixture would silently
    /// only ever exercise the public path.
    private func makeFixture(mode: LiquidGlassCaptureMode = .viewTree) throws
        -> (LiquidGlassEngine, LiquidGlassView, LiquidGlassBackdrop, UIWindow) {
        let engine = try XCTUnwrap(LiquidGlassEngine.shared, "Metal unavailable")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.makeKeyAndVisible()
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let source = UIView(frame: container.bounds)
        let quadrants: [(CGRect, UIColor)] = [
            (CGRect(x: 0, y: 0, width: 100, height: 100), .red),
            (CGRect(x: 100, y: 0, width: 100, height: 100), .green),
            (CGRect(x: 0, y: 100, width: 100, height: 100), .blue),
            (CGRect(x: 100, y: 100, width: 100, height: 100), .white),
        ]
        for (rect, color) in quadrants {
            let quadrant = UIView(frame: rect)
            quadrant.backgroundColor = color
            source.addSubview(quadrant)
        }
        container.addSubview(source)

        let glass = LiquidGlassView(frame: CGRect(x: 40, y: 40, width: 120, height: 120))
        container.addSubview(glass)

        var configuration = LiquidGlassConfiguration.regular
        configuration.thickness = 0            // no refraction -> zero displacement
        configuration.frost = 0                // read the sharp capture, not the pyramid
        configuration.chromaticAberration = 0
        configuration.saturation = 1
        configuration.adaptivity = 0
        configuration.specular = 0
        configuration.fresnel = 0
        configuration.innerShadow = 0
        configuration.motionResponsive = false
        glass.configuration = configuration
        glass.cornerRadius = 0

        let backdrop = try XCTUnwrap(LiquidGlassBackdrop(sourceView: source))
        backdrop.captureScale = 1.0
        backdrop.captureMode = mode
        glass.backdrop = backdrop

        container.setNeedsLayout()
        container.layoutIfNeeded()
        glass.layoutIfNeeded()
        // Let the render server actually composite: drawHierarchy(afterScreenUpdates:
        // false) reads what is already on screen.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return (engine, glass, backdrop, window)
    }

    private func makeTarget(engine: LiquidGlassEngine, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
    }

    private func render(engine: LiquidGlassEngine,
                        glass: LiquidGlassView,
                        backdrop: LiquidGlassBackdrop,
                        target: MTLTexture) throws {
        XCTAssertTrue(backdrop.captureIfNeeded(), "backdrop capture failed")
        let commandBuffer = try XCTUnwrap(engine.commandQueue.makeCommandBuffer())
        engine.encodePyramid(for: backdrop, into: commandBuffer)
        XCTAssertTrue(glass.encodeGlass(into: commandBuffer, target: target,
                                        light: SIMD3<Float>(0, 0, 1)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func readPixel(_ texture: MTLTexture, x: Int, y: Int)
        -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}

private func XCTAssertEqual(_ lhs: Int, _ rhs: Int, accuracy: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(lhs - rhs) <= accuracy, "\(lhs) is not within \(accuracy) of \(rhs)",
                  file: file, line: line)
}
