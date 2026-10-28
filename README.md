# Liquid Glass for iOS 15+

Apple's iOS 26 glass material, rebuilt from scratch so it runs on iOS 15 and up. One Metal shader: real Snell's-law refraction, chromatic dispersion on the rim, a specular highlight driven by the gyroscope, adaptive tinting, SDF blob merging, and an elastic stretch under the finger. No private API on the default path.

## See it first

`Example/` is one glass compose button over a generated backdrop. Open `Example/LiquidGlassExample.xcodeproj`, set your team under Signing & Capabilities, run it on a phone and drag the button around.

## Adding it

In Xcode: File → Add Package Dependencies… → Add Local…, point it at the folder with `Package.swift`, attach the `LiquidGlass` product to your target.

From a remote, same dialog with the repository URL. Or in a `Package.swift`:

```swift
.package(url: "https://github.com/YOU/LiquidGlass.git", from: "1.0.0")
```

Version rules only resolve against a tag, so `git tag 1.0.0 && git push --tags`. Without one, use `branch: "main"` instead (Dependency Rule → Branch in the dialog).

No SwiftPM? Drop `Sources/LiquidGlass` into your project. The sources land in your own module and you can skip the `import`.

## Using it

Apple reads what sits behind a glass element through `CABackdropLayer`, which is private. Public API has nothing that hands you the composited backdrop, so this library captures it itself, and it has to be told what "behind" means.

```swift
import LiquidGlass

final class MyViewController: UIViewController {
    private let contentView = UIView()          // everything the glass refracts
    private let bar = LiquidGlassView()
    private var backdrop: LiquidGlassBackdrop?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(contentView)            // wallpaper, scroll view, anything

        backdrop = LiquidGlassBackdrop(sourceView: contentView)
        bar.backdrop = backdrop
        bar.cornerRadius = -1                   // negative = capsule
        view.addSubview(bar)                    // ABOVE contentView, never inside it
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        contentView.frame = view.bounds
        bar.frame = CGRect(x: 16, y: view.bounds.height - 140,
                           width: view.bounds.width - 32, height: 64)
    }
}
```

The one rule you can't break: a glass view is a sibling *above* its `sourceView`, never a subview. Put it inside and it captures itself. Hall of mirrors.

Use one `LiquidGlassBackdrop` per screen and share it. It gets captured once a frame no matter how many pieces of glass read from it.

### A button that stretches under the finger

The deformation is drawn inside the view's own `bounds`, so the view needs room around the shape. The shape itself goes through `shapes`.

```swift
let room: CGFloat = 40, size: CGFloat = 56

button.backdrop = backdrop
button.elasticity = 1
button.frame = CGRect(x: 100, y: 300, width: size + room * 2, height: size + room * 2)
button.shapes = [LiquidGlassShape(rect: CGRect(x: room, y: room, width: size, height: size))]
button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pull)))

@objc func pull(_ recognizer: UIPanGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed: button.pullPoint = recognizer.location(in: button)
    default: button.pullPoint = nil
    }
}
```

Add the icon as an ordinary subview, centered with constraints. It rides the deformation on its own.

### Styling

```swift
bar.configuration = .regular       // adaptive, the default
bar.configuration = .clear         // permanently transparent, for bold media
bar.configuration = .thick         // heavy lens, for cards and sheets

var custom = LiquidGlassConfiguration.regular
custom.bevel = 18                  // width of the refracting rim
custom.thickness = 14              // how hard it bends
custom.tint = UIColor.systemBlue.withAlphaComponent(0.12)
bar.configuration = custom
```

**Read this before you ship: `isLive` defaults to `true`.** A live backdrop re-rasterizes the source view on the main thread every frame and redraws every glass view on it, even when nothing on screen moves. Static backdrop? Set `backdrop?.isLive = false` and call `setNeedsCapture()` when something changes (a scroll view's offset, a new image). An idle screen then costs nothing: with no live backdrop and nothing dirty, the engine stops creating command buffers and, when no view follows the gyroscope, puts its display link to sleep. Anything that gives it work wakes it again. That capture is the whole cost of the material.

#### Tint per shape

A `LiquidGlassShape` can carry its own tint. A shape without one wears `configuration.tint`.

```swift
bar.shapes = [
    LiquidGlassShape(rect: search),
    LiquidGlassShape(rect: done, tint: UIColor.systemPurple.withAlphaComponent(0.8)),
]
```

Where two shapes merge, their tints blend across the neck.

## How the material is built

Per fragment, in `Shaders.metal`:

1. **Shape.** Signed distance field of a rounded box. The corner distance uses a p-norm instead of L2, so `cornerExponent ≈ 4.2` reproduces iOS continuous corners. Capsules are exempt and always use L2: continuous corners belong to rounded *rectangles*, and a circle put through a 4.2-norm comes out a rounded square. Several shapes combine with a polynomial smooth-min, which is what makes neighboring blobs merge rather than overlap.
2. **Bevel.** `x` runs 0 at the outer edge to 1 at full bevel depth, and the surface height follows the convex squircle `h = (1-(1-x)⁴)^¼`. Apple prefers that profile because its shoulder is softer than a sphere's, which is what holds up on stretched rectangles. The derivative `u³/h³` blows up at the rim (clamped), which is exactly where glass bends light hardest.
3. **Refraction.** The height gradient gives a 3D normal, `refract()` applies Snell's law with `refractiveIndex` (1.52 by default), and the refracted ray is projected onto the backplane to get the sampling offset. So the rim drags the background outward and magnifies it, the way real glass does.
4. **Dispersion.** R, G and B sample at slightly different offsets, weighted toward the rim, since the flat center of a lens disperses nothing.
5. **Frost.** A mip pyramid of the backdrop, built by repeated 4-tap tent downsampling. That converges on a gaussian, so no separate blur pass is needed. Each glass view picks its own `blurRadius` as a LOD off the one shared pyramid. The rim reads the sharp lens, the center reads the frost.
6. **Adaptivity.** A coarse mip gives the local backdrop luminance and the veil moves between dark and light accordingly. This is what keeps a label on glass legible over both a black photo and a white one.
7. **Light.** A narrow radial window times a Blinn-Phong lobe, so the highlight is a thin arc hugging the lit edge rather than a soft blob. A second, weaker lobe lights the opposite rim (light that made it through), plus a Fresnel outline and contact darkening on the shadow side. `CMMotionManager` gravity drives the light direction, so the highlight swings as you tilt the phone.

## Deformation

`elasticity` turns both of these on. 0 is rigid.

**`pullPoint`** suits elements that stay put while you drag on them: a bar, a button. Feed it from your own gesture. The point at `.began` is the grab, and travel from there stretches the shape. Far edge holds, near edge travels, and the shape thins across the pull, so a circle is drawn into an oval instead of just inflating. Capped at 14% of the short side, eased so the first points of travel move it most, and it settles back on release. On a 56pt circle pulled down: top edge unmoved, bottom +8pt, width −5pt.

Driving it off distance from the shape's *edge* rather than from the grab point looks obvious and is wrong. A 76pt button then does nothing at all until your finger is 38pt clear of it.

Subviews ride the deformation as a transform: the centroid's travel plus the change in proportions. A glyph follows the finger *and* narrows with the glass around it, while Auto Layout underneath stays untouched.

**Moving `shapes`** gives the other half. A shape that travels leaves a spring-lagged droplet behind it, joined by the same smooth-min that merges neighboring blobs, so it elongates along its path and settles back with a wobble. Nothing is emitted at rest.

Both deform shapes *inside* the view, never the view itself. The drawable only covers `bounds`, so a stretch above a 64pt bar has nowhere to be drawn and gets clipped. Give the view the room the deformation needs and put the shape at its edge. In the example the button sits in a canvas 40pt larger on every side.

Reduce Motion forces both to 0, matching the system, which disables the elastic properties of the material there.

There's deliberately no press-to-squeeze. Widening the bevel on touch reads as the control swelling, not as glass giving way. The system's own interactive glass does swell under a finger and bounce back on release; that is UIKit's, and it is not reproduced here.

## Animating between shapes

`setShapes(_:animated:)` moves a view from one set of shapes to another, the way the system's glass moves when its pills merge. Shapes are matched by index, so the count has to stay the same.

```swift
glass.setShapes([qr, search, done], animated: true)
```

If a shape ends up inside another one without having started in it, it *goes into* it; if it starts inside one and ends outside, it *comes out of* it. That partner changes what happens:

- Every shape that changes travels on its own spring (0.416 s response, 0.75 damping by default).
- The partner starts at once. A pill that goes in waits 0.083 s; one that comes out starts at once.
- The mover travels to the partner's frame (or out of it) and shrinks to a fifth of its size on the way, or grows from a fifth.
- It first recoils from its partner by a sixth of the distance between their centres, then returns with a little bounce, so it winds up before it goes in and overshoots on the way out.
- Both swell and spring back (the pulse): up to 1.2x per axis, capped at 16 pt of growth, height returning a little before width, about the side of the view the partner sits on. A shape that changes with no partner pulses about its centre.
- Tints cross-fade on the shapes' spring from the very start.
- A neck of glass bridges the shapes while they cross. Its radius is zero at both ends, so shapes that end apart stay apart and shapes that end on top of each other end as one shape, never inflated.

Everything is in `LiquidGlassMorph` (`glass.morph`): `stiffness`, `dampingRatio`, `bulge` (neck thickness), `pulse` (1 turns it off), `kick` (0 turns it off) and `timeScale` (5 plays it five times slower, for tuning by eye). A pill that goes into another should end on top of it: when the move settles the view shows `shapes` exactly, so whatever it ends as must be hidden inside its partner.

What you lay over the glass follows it frame for frame:

```swift
glass.onMorphStep = { dt in                    // seconds of animation time this step covered
    let shapes = glass.displayedShapes         // as drawn right now: moved, recoiled, pulsed
    let scales = glass.displayedScales         // the shrink and the pulse, to scale an icon by
    // place your icons from these
}
```

`morphProgress` is 0 at the start and 1 once settled. Setting `shapes` directly jumps and cancels a morph in flight. Under Reduce Motion, or with no window yet, `setShapes` jumps instead.

The motion is modelled on how the system's glass behaves when pills merge in a navigation bar; the defaults were tuned to that, not measured against the system here. The `Example` is a single button and does not show it. A pill's contents (the icon that shrinks as it goes in, the label that grows to 1.2 and fades as it is swapped) are yours to animate. The same spring and the same clock (`onMorphStep`'s `dt`) are what they should run on.

## Baking glass into an image

A `LiquidGlassView` costs a backdrop capture and a Metal draw whenever it moves or its backdrop changes. Glass that does not need to be live, a capsule riding inside scrolling content over a wallpaper you control, can be rendered once into an image instead, which the compositor draws for free:

```swift
// The light on the rim, as a layer you put over your own frosted body.
let rim = LiquidGlassBaker.image(size: CGSize(width: 96, height: 28), content: .rimOverlay)?
    .resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14),
                    resizingMode: .stretch)

// Or the whole glass over a picture.
let glass = LiquidGlassBaker.image(size: size, content: .glass(over: wallpaper))
```

`.rimOverlay` is only the highlight arc, the Fresnel outline and the contact shade, transparent inside and outside the shape and independent of any backdrop. Over a backdrop it reads as `backdrop * (1 - shade) + light`, up to the cross term. A baked image gives up everything that depends on what is under the glass at the moment: the refraction follows the backdrop it was baked over, and the highlight is fixed (`configuration.staticLightDirection`) rather than swinging with the gyroscope. Main thread only.

## Accessibility

**Reduce Transparency** turns the glass into an opaque plate of one grey: dark in dark mode, light in light mode, with a hairline edge so the shape still reads. Nothing of the backdrop shows through, so neighbouring shapes are the same plate wherever they sit. It reacts as the setting changes. **Reduce Motion** disables the elastic deformation and makes `setShapes` jump. Increase Contrast is not handled.

## Knobs

`bevel` and `thickness` do most of the work. Bevel is how wide the refracting band is, thickness is how hard it bends. The rest lives in `LiquidGlassConfiguration.swift`. Glass gets tuned by eye on a real panel; constants that looked right in the simulator will not survive an OLED.

## Limits worth knowing before you ship it

**`CALayer.render(in:)` can't draw everything.** `UIVisualEffectView`, `AVPlayerLayer` and other `CAMetalLayer` content come out blank in the capture. Glass over video needs `.compositedBackdrop`, see below.

**The capture is CPU work on the main thread.** `medianCaptureMilliseconds` reports it. A single frame's number is noise.

`captureRect = nil` already sizes the capture to the union of the glass views on that backdrop, grown by their blur and refraction reach. Cost is linear in area, so this is the biggest lever available. On an iOS 18 simulator, median of 120, `captureScale = 0.5`: **9.17 ms** with glass over the whole screen, **4.21 ms** for a tab bar alone. It's one bounding box, so glass at the top *and* bottom of a screen still costs the whole screen. Give those two separate backdrops.

Beyond that: `isLive = false` for a static backdrop plus `setNeedsCapture()` when it changes, which is free. And `captureScale`, where cost is quadratic. Only the thin rim lens reads the backdrop sharply, so there's more headroom there than you'd expect.

Already measured, not worth retrying: `drawHierarchy(afterScreenUpdates: false)` in place of `render(in:)`. WWDC 2013 session 226 puts it at "up to 8x" faster. Here it was **slower**, 10.50 vs 9.14 ms full-screen and 7.84 vs 4.62 ms cropped. The gap widens when cropped, which says it snapshots the whole view and the context clip doesn't cull its work.

**Backdrop-relative, not screen-relative.** Glass views must be siblings above the source view. Put one inside and it captures itself.

**The private `CABackdropLayer` path is implemented and isn't worth it.** `backdrop.captureMode = .compositedBackdrop` parks a `CABackdropLayer` above the source view and rasterizes the real composited backdrop, which does see video and `UIVisualEffectView`. It is not faster. Median of 120 captures, full-screen live capture at `captureScale = 0.5`:

| | `.viewTree` (public) | `.compositedBackdrop` (private) |
|---|---|---|
| iOS 18.0 sim | 9.08 ms / 60 fps | 9.59 ms / 60 fps |
| iOS 26.2 sim | ~10.3 ms / 60 fps | **33.31 ms / 23 fps** |

Which is why there's no `.automatic` mode: it could only ever be a trap that picks the slow one. Opt in when the backdrop is something `render(in:)` cannot draw, and remember it's private API that App Store analysis flags. If the render server returns nothing, the capture falls back to `.viewTree` and stays there.

**SDF cost** is 5 evaluations per pixel per shape, the gradient being central differences. Fine for UI-sized elements. Go analytic before covering a whole screen with a 12-shape group.

**At most 12 shapes** per view (`LiquidGlassView.maxShapeCount`), trailing droplets included. Leaders come first, so a trail never displaces a real shape; extra shapes are not drawn.

**No SwiftUI wrapper.** The explicit-backdrop model doesn't map onto SwiftUI without a container abstraction, and that's a design decision rather than a missing shim.

## Tests

```
xcodebuild -scheme LiquidGlass -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

They cover what you can't see by looking at the screen. With refraction, frost, tint, saturation and light all neutralized, the glass has to be a pixel-exact pass-through of the backdrop underneath it. Outside the rounded corner the fragment has to be fully transparent. A merge radius has to bridge a gap without moving the shapes. A pull has to stretch the shape and settle back, and a glyph has to ride the deformation.

The newer behaviour is pinned the same way, as properties rather than as the code that makes them true. Two shapes with two tints must each show their own. With Reduce Transparency on, the plate over red and the plate over white must be the same grey, and dark mode and light mode must differ. A morph must start where the shapes are, land exactly on the target and leave no neck, no pulse and no recoil behind. A pill that goes into another must wait, shrink and be sucked into the partner's frame, one that comes out must start at once and be thrown past its place, and the partner must swell about the side it sits on even if it does not move. The engine must sleep when there is nothing to do and wake for every kind of change. A baked rim must be hollow inside and outside the shape and lit where the light is.

The point is that a wrong uniform layout, a flipped UV or a bad coordinate conversion all still produce something glass-looking. These turn that into a red test.

Each was checked by reverse run, breaking the thing it guards: swap two fields in `LGUniforms` and the pass-through test fails, remove the content transform and the glyph test fails, drop the engine's wake-up and the sleep test fails, give every shape the view's tint and the per-shape tint tests fail, let the Reduce Transparency plate follow the backdrop's brightness and its test fails, and remove the merge delay, the shrink or the recoil and the matching morph test fails.

## Sources

- [Liquid Glass in the Browser: Refraction with CSS and SVG, kube.io](https://kube.io/blog/liquid-glass-css-svg/), for the height profiles, normals and displacement math
- [Liquid Glass: iOS Effect Explanation, AmirHossein Aghajari](https://medium.com/@aghajari/liquid-glass-ios-effect-explanation-dabadd6414ae), for the SDF, lens curve and edge-only aberration
- [Implementing a Refractive Glass Shader in Metal, Victor Baro](https://medium.com/@victorbaro/implementing-a-refractive-glass-shader-in-metal-3f97974fbc24) and [SDF in Metal: Adding the Liquid to the Glass](https://medium.com/@victorbaro/sdf-in-metal-adding-the-liquid-to-the-glass-69abd57e2151)
- [Meet Liquid Glass, WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/), for Regular vs Clear, adaptive tinting and motion-driven highlights

## License

MIT.
