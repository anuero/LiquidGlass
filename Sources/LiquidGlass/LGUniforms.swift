import simd

/// CPU mirror of the structs in Shaders.metal.
///
/// Every scalar sits at its natural 4-byte offset and both `SIMD4` members land
/// on a 16-byte boundary, so simd and Metal Shading Language lay these out
/// identically without a shared C header. `LiquidGlassEngine` asserts the
/// strides at startup so a future edit that breaks the rule fails loudly.
struct LGShape {
    var center = SIMD2<Float>(0, 0)          // px, origin top-left of the glass view
    var halfSize = SIMD2<Float>(0, 0)        // px
    var cornerRadius: Float = 0              // px
    var cornerExponent: Float = 4.2          // 2 = circular, ~4.2 = iOS continuous corners
    var _pad0: Float = 0
    var _pad1: Float = 0
}

struct LGUniforms {
    var viewSize = SIMD2<Float>(0, 0)        // px
    var backdropOrigin = SIMD2<Float>(0, 0)  // pt, view origin inside the capture
    var backdropInvSize = SIMD2<Float>(0, 0) // 1 / capture size in pt
    var scale: Float = 1                     // px per pt
    var shapeCount: Float = 0

    var tint = SIMD4<Float>(0, 0, 0, 0)          // rgb + strength
    var lightDirBevel = SIMD4<Float>(0, 0, 1, 8) // xyz = light direction, w = bevel px

    var thickness: Float = 0
    var ior: Float = 1.5
    var chroma: Float = 0
    var frost: Float = 1

    var saturation: Float = 1
    var adaptivity: Float = 1
    var darkVeil: Float = 0
    var lightVeil: Float = 0

    var specular: Float = 0
    var shininess: Float = 40
    var fresnel: Float = 0
    var innerShadow: Float = 0

    var mergeRadius: Float = 0
    var blurLOD: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
}
