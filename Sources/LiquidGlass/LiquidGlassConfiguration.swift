import UIKit

/// Every knob of the material. Values are in **points**, not pixels.
///
/// The defaults are tuned to sit on top of iOS 26's system Liquid Glass; the
/// `UIGlassEffect` on iOS 26, so dial them in on the device you care about.
public struct LiquidGlassConfiguration: Equatable {

    // MARK: Geometry

    /// Width of the refracting rim band, in points. This is the single most
    /// visible parameter: too small reads as a hard plastic edge, too large
    /// swallows the flat center.
    public var bevel: CGFloat = 14

    /// Virtual depth of the glass, in points. Drives how far the rim drags the
    /// background inward.
    public var thickness: CGFloat = 11

    /// Refractive index. 1.0 = no bending, 1.5 = glass, 2.4 = diamond.
    public var refractiveIndex: CGFloat = 1.52

    /// Corner shape. 2 = circular corners, ~4.2 matches iOS continuous corners.
    public var cornerExponent: CGFloat = 4.2

    /// Smooth-min radius between shapes, in points. > 0 makes neighboring
    /// shapes merge like droplets instead of overlapping.
    public var mergeRadius: CGFloat = 0

    // MARK: Optics

    /// Prismatic color separation on the rim.
    public var chromaticAberration: CGFloat = 0.045

    /// How frosted the flat center is. 0 = clear lens, 1 = fully blurred.
    public var frost: CGFloat = 1.0

    /// Blur radius of the frosted core, in points.
    public var blurRadius: CGFloat = 24

    /// Backdrop saturation boost, the reason system materials look "alive".
    public var saturation: CGFloat = 1.45

    // MARK: Tint & adaptivity

    /// Explicit tint. Alpha is the strength.
    public var tint: UIColor? = nil

    /// How strongly the glass follows the brightness of what is behind it.
    public var adaptivity: CGFloat = 1.0

    /// Veil opacity over dark backdrops.
    public var darkVeil: CGFloat = 0.28

    /// Veil opacity over bright backdrops.
    public var lightVeil: CGFloat = 0.34

    // MARK: Light

    /// Directional specular intensity.
    public var specular: CGFloat = 0.6

    /// Specular tightness. Higher = thinner, sharper highlight line.
    public var shininess: CGFloat = 90

    /// Fresnel rim brightness, the thin light outline around the whole shape.
    public var fresnel: CGFloat = 0.22

    /// Contact darkening on the rim facing away from the light.
    public var innerShadow: CGFloat = 0.22

    /// Let the device gyroscope drive the light direction.
    public var motionResponsive: Bool = true

    /// Light direction used when motion is off or unavailable.
    public var staticLightDirection = SIMD3<Float>(-0.45, -0.72, 0.53)

    // MARK: Shadow

    public var shadowOpacity: CGFloat = 0.18
    public var shadowRadius: CGFloat = 14
    public var shadowOffset = CGSize(width: 0, height: 6)

    public init() {}

    // MARK: Presets

    /// Apple's "Regular": adaptive, legible on anything.
    public static var regular: LiquidGlassConfiguration { LiquidGlassConfiguration() }

    /// Apple's "Clear": permanently transparent, for bold media underneath.
    /// Carries its own dimming so content on top stays readable.
    public static var clear: LiquidGlassConfiguration {
        var c = LiquidGlassConfiguration()
        c.frost = 0.25
        c.blurRadius = 12
        c.adaptivity = 0.35
        c.darkVeil = 0.20
        c.lightVeil = 0.18
        c.saturation = 1.35
        c.thickness = 14
        c.specular = 0.7
        return c
    }

    /// Thick, heavily-lensed slab, good for large cards and sheets.
    public static var thick: LiquidGlassConfiguration {
        var c = LiquidGlassConfiguration()
        c.bevel = 22
        c.thickness = 20
        c.blurRadius = 40
        c.chromaticAberration = 0.06
        return c
    }
}
