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
        XCTAssertEqual(MemoryLayout<LGShape>.stride, 48)
        // a float4, so it starts on a 16-byte boundary
        XCTAssertEqual(MemoryLayout<LGShape>.offset(of: \.tint), 32)
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

    // MARK: Per-shape tint

    // a view-wide tint can't pass this, one colour would cover both
    func testEachShapeWearsItsOwnTintAndOneWithoutWearsTheViews() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        var configuration = glass.configuration
        configuration.tint = UIColor(red: 0, green: 1, blue: 0, alpha: 1)    // the view's: green
        glass.configuration = configuration
        glass.shapes = [
            LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 50, height: 40)),            // no tint: green
            LiquidGlassShape(rect: CGRect(x: 70, y: 40, width: 50, height: 40),
                             tint: UIColor(red: 1, green: 0, blue: 0, alpha: 1)),          // red
        ]
        glass.layoutIfNeeded()
        let scale = glass.layer.contentsScale
        let target = try makeTarget(engine: engine, width: Int(glass.bounds.width * scale),
                                    height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)

        let left = readPixel(target, x: Int(25 * scale), y: Int(60 * scale))
        XCTAssertEqual(Int(left.green), 255, accuracy: 6, "a shape with no tint wears the view's")
        XCTAssertEqual(Int(left.red), 0, accuracy: 6, "and none of its neighbour's")
        let right = readPixel(target, x: Int(95 * scale), y: Int(60 * scale))
        XCTAssertEqual(Int(right.red), 255, accuracy: 6, "a shape's own tint wins over the view's")
        XCTAssertEqual(Int(right.green), 0, accuracy: 6)
    }

    // merged, the tints blend across the neck and the ends keep their own
    func testTintsBlendAcrossTheNeckOfMergedShapes() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        var configuration = glass.configuration
        configuration.mergeRadius = 120
        glass.configuration = configuration
        glass.shapes = [
            LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40),
                             tint: UIColor(red: 0, green: 0, blue: 1, alpha: 1)),
            LiquidGlassShape(rect: CGRect(x: 80, y: 40, width: 40, height: 40),
                             tint: UIColor(red: 1, green: 0, blue: 0, alpha: 1)),
        ]
        glass.layoutIfNeeded()
        let scale = glass.layer.contentsScale
        let target = try makeTarget(engine: engine, width: Int(glass.bounds.width * scale),
                                    height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)

        let middle = readPixel(target, x: Int(60 * scale), y: Int(60 * scale))
        XCTAssertGreaterThan(Int(middle.red), 40, "the neck carries some of the right shape's colour")
        XCTAssertGreaterThan(Int(middle.blue), 40, "and some of the left shape's")
        XCTAssertLessThan(Int(middle.red), 215, "without either one taking it over")
        XCTAssertLessThan(Int(middle.blue), 215)
    }

    // MARK: Reduce Transparency

    // probed over red and over white, the two ends of the brightness range
    func testReduceTransparencyDrawsAnOpaquePlateThatIgnoresTheBackdrop() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        let scale = glass.layer.contentsScale

        func probe(solid: Bool) throws -> (top: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
                                           bottom: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)) {
            glass.reduceTransparencyOverride = solid
            let target = try makeTarget(engine: engine, width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
            return (readPixel(target, x: Int(30 * scale), y: Int(30 * scale)),     // over red
                    readPixel(target, x: Int(90 * scale), y: Int(90 * scale)))     // over white
        }

        let clear = try probe(solid: false)
        XCTAssertEqual(Int(clear.top.green), 0, accuracy: 4, "transparent: red over red")
        XCTAssertEqual(Int(clear.bottom.green), 255, accuracy: 4, "transparent: white over white")

        let plate = try probe(solid: true)
        XCTAssertEqual(plate.top.alpha, 255, "the plate is opaque")
        XCTAssertEqual(plate.bottom.alpha, 255)
        // one grey for the whole view, a plate that followed the backdrop would differ
        XCTAssertEqual(Int(plate.top.red), Int(plate.bottom.red), accuracy: 2)
        XCTAssertEqual(Int(plate.top.green), Int(plate.bottom.green), accuracy: 2)
        XCTAssertEqual(Int(plate.top.blue), Int(plate.bottom.blue), accuracy: 2)
        XCTAssertEqual(Int(plate.top.red), Int(plate.top.blue), accuracy: 2, "and it is a grey, not the backdrop's red")
    }

    func testReduceTransparencyPlateFollowsTheAppearance() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        glass.reduceTransparencyOverride = true
        let scale = glass.layer.contentsScale

        func plateRed(_ style: UIUserInterfaceStyle) throws -> Int {
            glass.overrideUserInterfaceStyle = style
            // uikit applies the style on its next pass, not on assignment
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let target = try makeTarget(engine: engine, width: Int(glass.bounds.width * scale),
                                        height: Int(glass.bounds.height * scale))
            try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
            return Int(readPixel(target, x: Int(60 * scale), y: Int(60 * scale)).red)
        }

        XCTAssertLessThan(try plateRed(.dark), 70, "a dark plate in dark mode")
        XCTAssertGreaterThan(try plateRed(.light), 200, "a light plate in light mode")
    }

    // MARK: Animated shapes

    // starts where the shapes are, lands exactly, leaves no neck behind
    func testSetShapesMorphsOnASpringAndLandsExactlyWithNoNeckLeft() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { window.isHidden = true }
        let start = [LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40)),
                     LiquidGlassShape(rect: CGRect(x: 80, y: 40, width: 40, height: 40))]
        let end = [LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40)),
                   LiquidGlassShape(rect: CGRect(x: 50, y: 40, width: 40, height: 40))]
        glass.shapes = start
        glass.setShapes(end, animated: true)

        XCTAssertTrue(glass.isMorphing)
        XCTAssertEqual(glass.displayedShapes, start, "it starts exactly where the shapes are")
        XCTAssertEqual(glass.morphNeck, 0, "no neck before it moves")

        for _ in 0..<6 { glass.stepAnimation(duration: 1.0 / 60) }
        let middle = glass.displayedShapes[1].rect.minX
        XCTAssertGreaterThan(middle, 50, "it has left its start")
        XCTAssertLessThan(middle, 80, "and is not there yet")
        XCTAssertGreaterThan(glass.morphNeck, 5, "a neck bridges the shapes on the way")

        for _ in 0..<600 { glass.stepAnimation(duration: 1.0 / 60) }
        XCTAssertFalse(glass.isMorphing, "it settles")
        XCTAssertEqual(glass.displayedShapes, end, "and lands exactly on the target")
        XCTAssertEqual(glass.morphNeck, 0, "with no neck left")

        // drawn, the 10pt gap between the landed shapes is empty
        glass.layoutIfNeeded()
        let scale = glass.layer.contentsScale
        let target = try makeTarget(engine: engine, width: Int(glass.bounds.width * scale),
                                    height: Int(glass.bounds.height * scale))
        try render(engine: engine, glass: glass, backdrop: backdrop, target: target)
        XCTAssertEqual(readPixel(target, x: Int(45 * scale), y: Int(60 * scale)).alpha, 0,
                       "shapes that ended apart stay apart")
        XCTAssertEqual(readPixel(target, x: Int(20 * scale), y: Int(60 * scale)).alpha, 255)
        XCTAssertEqual(readPixel(target, x: Int(70 * scale), y: Int(60 * scale)).alpha, 255)
    }

    // MARK: Pulse

    // a still shape on the left, one on the right travelling toward it (80 -> 50)
    private func pulseShapes() -> (start: [LiquidGlassShape], end: [LiquidGlassShape]) {
        let still = LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40))
        return ([still, LiquidGlassShape(rect: CGRect(x: 80, y: 40, width: 40, height: 40))],
                [still, LiquidGlassShape(rect: CGRect(x: 50, y: 40, width: 40, height: 40))])
    }

    private func trajectory(_ glass: LiquidGlassView, pulse: CGFloat, frames: Int = 240)
        -> (moving: [CGRect], still: [CGRect]) {
        let (start, end) = pulseShapes()
        glass.morph.pulse = pulse
        glass.shapes = start
        glass.setShapes(end, animated: true)
        var moving: [CGRect] = [], still: [CGRect] = []
        for _ in 0..<frames {
            glass.stepAnimation(duration: 1.0 / 60)
            moving.append(glass.displayedShapes[1].rect)
            still.append(glass.displayedShapes[0].rect)
        }
        return (moving, still)
    }

    func testPulseSwellsOnlyTheShapeThatChangesAndLandsExactly() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let (start, end) = pulseShapes()

        let plain = trajectory(glass, pulse: 1)
        XCTAssertEqual(plain.moving.map { $0.height }.max(), 40, "pulse off: the height never changes")

        let pulsed = trajectory(glass, pulse: 1.2)
        let peak = try XCTUnwrap(pulsed.moving.map { $0.height }.max())
        XCTAssertGreaterThan(peak, 44, "the shape that moves swells at the peak of its pulse (1.2 x 40 = 48)")
        XCTAssertLessThan(peak, 56, "but only by the pulse's cap, not without bound")
        XCTAssertTrue(pulsed.still.allSatisfy { $0 == start[0].rect },
                      "a shape that does not change does not pulse, whatever its neighbour does")

        XCTAssertFalse(glass.isMorphing, "the pulse settles too")
        XCTAssertEqual(glass.displayedShapes, end, "and nothing of it is left on the shapes")
    }

    func testShapeWithNoPartnerPulsesAboutItsCentre() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let plain = trajectory(glass, pulse: 1)
        let pulsed = trajectory(glass, pulse: 1.2)

        var swelled = false
        for (a, b) in zip(plain.moving, pulsed.moving) {
            XCTAssertEqual(b.midX, a.midX, accuracy: 0.001, "the centre does not move")
            XCTAssertEqual(b.midY, a.midY, accuracy: 0.001)
            if b.width > a.width + 2 { swelled = true }
        }
        XCTAssertTrue(swelled, "and it clearly swells at some point")
    }

    // MARK: Merging pills

    // a still shape on the right and one that goes into it, or comes out of it
    private func mergingShapes(collapsing: Bool) -> (start: [LiquidGlassShape], end: [LiquidGlassShape]) {
        let partner = LiquidGlassShape(rect: CGRect(x: 70, y: 40, width: 50, height: 40))
        let apart = LiquidGlassShape(rect: CGRect(x: 0, y: 40, width: 40, height: 40))
        let inside = LiquidGlassShape(rect: CGRect(x: 75, y: 40, width: 40, height: 40))
        return collapsing ? ([apart, partner], [inside, partner]) : ([inside, partner], [apart, partner])
    }

    private func frames(_ glass: LiquidGlassView, _ shapes: (start: [LiquidGlassShape], end: [LiquidGlassShape]),
                        pulse: CGFloat = 1.2, kick: CGFloat = 1.0 / 6.0, count: Int = 240) -> [[CGRect]] {
        glass.morph.pulse = pulse
        glass.morph.kick = kick
        glass.shapes = shapes.start
        glass.setShapes(shapes.end, animated: true)
        var result: [[CGRect]] = []
        for _ in 0..<count {
            glass.stepAnimation(duration: 1.0 / 60)
            result.append(glass.displayedShapes.map { $0.rect })
        }
        return result
    }

    func testShapeMovingIntoAnotherWaitsAndItsPartnerSwellsAtOnce() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let shapes = mergingShapes(collapsing: true)
        let run = frames(glass, shapes)

        // 0.083 s is five frames at 60 fps
        for frame in 0..<4 {
            XCTAssertEqual(run[frame][0], shapes.start[0].rect, "frame \(frame): the mover is still waiting")
        }
        XCTAssertNotEqual(run[6][0], shapes.start[0].rect, "and then it goes")
        // the partner never moves, yet it swells from the first frames
        XCTAssertNotEqual(run[3][1], shapes.end[1].rect, "the partner is already swelling while the mover waits")
        XCTAssertEqual(run[239][0], shapes.end[0].rect, "both land exactly")
        XCTAssertEqual(run[239][1], shapes.end[1].rect)
    }

    func testPartnerSwellsAboutTheSideItSitsOn() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let shapes = mergingShapes(collapsing: true)
        let run = frames(glass, shapes)
        let rest = shapes.end[1].rect

        var stretchedInward = false
        for frame in run {
            let partner = frame[1]
            XCTAssertEqual(partner.maxX, rest.maxX, accuracy: 0.001, "the trailing edge stays")
            XCTAssertEqual(rest.minY - partner.minY, partner.maxY - rest.maxY, accuracy: 0.001,
                           "centred on the vertical axis: grows up and down alike")
            if partner.minX < rest.minX - 2 { stretchedInward = true }
        }
        XCTAssertTrue(stretchedInward, "it stretches clearly toward the middle")
    }

    func testShapeMovingIntoAnotherRecoilsFirst() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let shapes = mergingShapes(collapsing: true)
        let withKick = frames(glass, shapes)
        let withoutKick = frames(glass, shapes, kick: 0)

        // the mover heads right, the recoil holds it back to the left
        let behind = zip(withKick, withoutKick).map { $0[0].minX - $1[0].minX }.min() ?? 0
        XCTAssertLessThan(behind, -5, "the recoil holds it clearly back at its deepest")
        XCTAssertEqual(withKick[239][0], withoutKick[239][0], "and leaves nothing behind")
    }

    func testShapeGrowingOutOfAnotherStartsAtOnceAndOvershootsOutward() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let shapes = mergingShapes(collapsing: false)
        let withKick = frames(glass, shapes)
        let withoutKick = frames(glass, shapes, kick: 0)
        let target = shapes.end[0].rect.minX

        XCTAssertNotEqual(withKick[0][0], shapes.start[0].rect, "it starts at once, with no wait")
        let overshoot = target - (withKick.map { $0[0].minX }.min() ?? target)
        let springOnly = target - (withoutKick.map { $0[0].minX }.min() ?? target)
        XCTAssertGreaterThan(overshoot, springOnly + 4, "the recoil throws it clearly past its place")
        XCTAssertEqual(withKick[239][0], shapes.end[0].rect, "and it comes back to rest exactly on it")
    }

    func testMatchedPillShrinksGoingInAndGrowsComingOut() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }

        let into = mergingShapes(collapsing: true)
        let goingIn = frames(glass, into)
        let narrowest = goingIn.map { $0[0].width }.min() ?? 0
        XCTAssertLessThan(narrowest, 14, "it gets much smaller than its own 40 pt on the way in (a fifth is 8-10)")
        // at some point it sits small inside the partner's frame
        let partner = into.end[1].rect
        XCTAssertTrue(goingIn.contains { partner.contains($0[0]) && $0[0].width < 20 },
                      "it ends up small inside the partner's frame")
        XCTAssertEqual(goingIn[239][0], into.end[0].rect, "and what is left once settled is its own rect, exactly")

        let out = mergingShapes(collapsing: false)
        glass.morph.pulse = 1.2
        glass.shapes = out.start
        glass.setShapes(out.end, animated: true)
        let atStart = glass.displayedShapes[0].rect
        XCTAssertLessThan(atStart.width, 14, "it starts small, inside its partner")
        XCTAssertTrue(out.end[1].rect.contains(atStart), "inside the partner's frame")
        let growing = frames(glass, out)
        XCTAssertEqual(growing[239][0], out.end[0].rect, "and grows to exactly its own rect")
    }

    func testTintFadesFromTheStartAndAChangeOfTintAloneDoesNotMove() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let accent = UIColor(red: 0.6, green: 0.4, blue: 1, alpha: 1)
        var shapes = mergingShapes(collapsing: true)
        let still = LiquidGlassShape(rect: CGRect(x: 0, y: 90, width: 30, height: 20))
        shapes.start[1].tint = nil
        shapes.end[0].tint = accent
        shapes.end[1].tint = accent
        shapes.start.append(still)
        shapes.end.append(LiquidGlassShape(rect: still.rect, tint: accent))

        glass.shapes = shapes.start
        glass.setShapes(shapes.end, animated: true)
        for _ in 0..<3 { glass.stepAnimation(duration: 1.0 / 60) }
        var alpha: CGFloat = 0
        glass.displayedShapes[0].tint?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(glass.displayedShapes[0].rect, shapes.start[0].rect, "the mover is still waiting")
        XCTAssertGreaterThan(alpha, 0.05, "yet its tint has begun to change")

        for _ in 0..<240 { glass.stepAnimation(duration: 1.0 / 60) }
        XCTAssertEqual(glass.displayedShapes, shapes.end)

        // a tint change alone keeps the rect on every frame
        glass.shapes = shapes.start
        glass.setShapes(shapes.end, animated: true)
        for _ in 0..<120 {
            glass.stepAnimation(duration: 1.0 / 60)
            XCTAssertEqual(glass.displayedShapes[2].rect, still.rect, "a change of tint is not a move")
        }
    }

    func testWithPulseAndKickOffThePartnerStaysPutAndTheMoverWaitsNoLonger() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let shapes = mergingShapes(collapsing: true)
        let run = frames(glass, shapes, pulse: 1, kick: 0)
        XCTAssertTrue(run.allSatisfy { $0[1] == shapes.end[1].rect }, "no pulse: the partner never moves")
    }

    func testSetShapesJumpsWhenNotAnimatedOrWhenTheCountChanges() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let one = [LiquidGlassShape(rect: CGRect(x: 0, y: 0, width: 40, height: 40))]
        let moved = [LiquidGlassShape(rect: CGRect(x: 50, y: 0, width: 40, height: 40))]
        let two = moved + one
        glass.shapes = one

        glass.setShapes(moved, animated: false)
        XCTAssertFalse(glass.isMorphing)
        XCTAssertEqual(glass.displayedShapes, moved)

        glass.setShapes(two, animated: true)
        XCTAssertFalse(glass.isMorphing, "a different count cannot be matched by index")
        XCTAssertEqual(glass.displayedShapes, two)
    }

    func testAssigningShapesDirectlyCancelsARunningMorph() throws {
        let (_, glass, _, window) = try makeFixture()
        defer { window.isHidden = true }
        let a = [LiquidGlassShape(rect: CGRect(x: 0, y: 0, width: 40, height: 40))]
        let b = [LiquidGlassShape(rect: CGRect(x: 60, y: 0, width: 40, height: 40))]
        let c = [LiquidGlassShape(rect: CGRect(x: 0, y: 60, width: 40, height: 40))]
        glass.shapes = a
        glass.setShapes(b, animated: true)
        glass.stepAnimation(duration: 1.0 / 60)
        glass.shapes = c
        XCTAssertFalse(glass.isMorphing)
        for _ in 0..<60 { glass.stepAnimation(duration: 1.0 / 60) }
        XCTAssertEqual(glass.displayedShapes, c)
    }

    // MARK: Engine idle

    // a link that sleeps through a change would leave stale glass
    func testEngineSleepsWhenThereIsNothingToDoAndAnyChangeWakesIt() throws {
        let (engine, glass, backdrop, window) = try makeFixture()
        defer { glass.removeFromSuperview(); window.isHidden = true }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        backdrop.isLive = false
        spin(0.5)
        XCTAssertTrue(engine.isAsleep, "nothing live, nothing dirty: it sleeps")

        glass.setNeedsGlassRedraw()
        XCTAssertFalse(engine.isAsleep, "a redraw request wakes it")
        spin(0.5)
        XCTAssertTrue(engine.isAsleep, "and it sleeps again once drawn")

        backdrop.setNeedsCapture()
        XCTAssertFalse(engine.isAsleep, "a capture request wakes it")
        spin(0.5)
        XCTAssertTrue(engine.isAsleep)

        glass.isHidden = true
        spin(0.2)
        glass.isHidden = false
        XCTAssertFalse(engine.isAsleep, "showing the view again wakes it")
        spin(0.5)
        XCTAssertTrue(engine.isAsleep)

        backdrop.isLive = true
        spin(0.4)
        XCTAssertFalse(engine.isAsleep, "a live backdrop keeps it running")
    }

    // MARK: Baking

    private struct Raster {
        let width: Int, height: Int
        let bytes: [UInt8]      // RGBA, premultiplied
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    private func raster(_ image: UIImage) throws -> Raster {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Raster(width: cg.width, height: cg.height, bytes: bytes)
    }

    // a layer that lit the whole body would wash out the frost under it
    func testBakedRimIsLitOnTheRimAndHollowInsideAndOutside() throws {
        let size = CGSize(width: 120, height: 44)
        let image = try XCTUnwrap(LiquidGlassBaker.image(size: size, content: .rimOverlay, scale: 2))
        XCTAssertEqual(image.size, size)
        XCTAssertEqual(image.scale, 2)
        let r = try raster(image)
        XCTAssertEqual(r.width, 240)
        XCTAssertEqual(r.height, 88)

        XCTAssertEqual(r.alpha(0, 0), 0, "outside the capsule")
        // deeper than the 14pt bevel reaches
        var hollow = 0
        for y in stride(from: 32, to: 56, by: 1) {                  // 16...28pt
            for x in stride(from: 50, to: 190, by: 1) where r.alpha(x, y) > 6 { hollow += 1 }
        }
        XCTAssertEqual(hollow, 0, "the body must stay clear")

        // the default light is upper left
        var lit = 0
        for x in 0..<120 { for y in 0..<44 where r.alpha(x, y) > 50 { lit += 1 } }
        XCTAssertGreaterThan(lit, 10, "the rim facing the light must carry its highlight")
    }

    func testBakedGlassOverAFlatBackdropKeepsItsColour() throws {
        var configuration = LiquidGlassConfiguration.regular
        configuration.thickness = 0
        configuration.frost = 0
        configuration.chromaticAberration = 0
        configuration.saturation = 1
        configuration.adaptivity = 0
        configuration.specular = 0
        configuration.fresnel = 0
        configuration.innerShadow = 0
        let red = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let image = try XCTUnwrap(LiquidGlassBaker.image(
            size: CGSize(width: 80, height: 40), configuration: configuration,
            content: .glass(over: red), scale: 2))
        let r = try raster(image)
        let center = r.pixel(80, 40)
        XCTAssertEqual(Int(center.r), 255, accuracy: 4)
        XCTAssertEqual(Int(center.g), 0, accuracy: 4)
        XCTAssertEqual(Int(center.b), 0, accuracy: 4)
        XCTAssertEqual(center.a, 255)
        XCTAssertEqual(r.alpha(0, 0), 0, "the corner of the capsule is outside it")
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
