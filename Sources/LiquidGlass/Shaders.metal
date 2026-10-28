//  Shaders.metal
//  The only non-Swift file in the project: GPU code has to be Metal Shading
//  Language. Layout of LGUniforms/LGShape mirrors LGUniforms.swift, every
//  scalar sits at its natural offset and both float4 members land on a
//  16-byte boundary, so simd and MSL agree with no padding ambiguity.

#include <metal_stdlib>
using namespace metal;

struct LGShape {
    float2 center;          // px, origin top-left of the glass view
    float2 halfSize;        // px
    float  cornerRadius;    // px
    float  cornerExponent;  // 2 = circular corners, ~4.2 = iOS continuous corners
    float  _pad0;
    float  _pad1;
    float4 tint;            // rgb + strength
};

struct LGUniforms {
    float2 viewSize;        // px
    float2 backdropOrigin;  // pt, view origin inside the captured backdrop
    float2 backdropInvSize; // 1 / capture size in pt
    float  scale;           // px per pt
    float  shapeCount;

    float4 tint;            // rgb + strength
    float4 lightDirBevel;   // xyz = light direction, w = bevel width in px

    float  thickness;       // px, virtual glass depth
    float  ior;             // refractive index
    float  chroma;          // chromatic aberration
    float  frost;

    float  saturation;
    float  adaptivity;
    float  darkVeil;
    float  lightVeil;

    float  specular;
    float  shininess;
    float  fresnel;
    float  innerShadow;

    float  mergeRadius;     // px, smooth-min between shapes ("liquid")
    float  blurLOD;         // mip level of the backdrop pyramid used for the frost
    float  solid;           // > 0: reduce transparency, an opaque plate of this grey
    float  overlay;         // 1: baked rim, only light and shade
};

constexpr sampler lgSampler(coord::normalized, address::clamp_to_edge,
                            filter::linear, mip_filter::linear);

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// Full-screen triangle. uv (0,0) = top-left of the render target.
vertex VOut lg_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv  = uv;
    return o;
}

// MARK: - Backdrop pyramid

fragment float4 lg_downsample(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant float2 &srcTexel [[buffer(0)]]) {
    float2 o = srcTexel;
    float4 c = src.sample(lgSampler, in.uv + float2(-o.x, -o.y))
             + src.sample(lgSampler, in.uv + float2( o.x, -o.y))
             + src.sample(lgSampler, in.uv + float2(-o.x,  o.y))
             + src.sample(lgSampler, in.uv + float2( o.x,  o.y));
    return c * 0.25;
}

// MARK: - Signed distance field

// Rounded box. cornerExponent > 2 gives iOS-style continuous ("squircle")
// corners by measuring the corner distance with a p-norm instead of L2.
static float sdRoundBox(float2 p, float2 b, float r, float n) {
    float2 q = abs(p) - b + r;
    float2 m = max(q, 0.0);
    float outside;
    if (n <= 2.02) {
        outside = length(m);
    } else {
        float s = pow(m.x, n) + pow(m.y, n);
        outside = (s > 0.0) ? pow(s, 1.0 / n) : 0.0;
    }
    return min(max(q.x, q.y), 0.0) + outside - r;
}

// Quadratic polynomial smooth-min, this is what makes neighboring shapes
// bleed into one blob instead of just overlapping.
static float lgSmin(float a, float b, float k) {
    if (k <= 0.0001) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static float sceneSDF(float2 p, constant LGUniforms &u, constant LGShape *shapes) {
    int n = int(u.shapeCount);
    float d = 1.0e9;
    for (int i = 0; i < n; ++i) {
        LGShape s = shapes[i];
        float r = min(s.cornerRadius, min(s.halfSize.x, s.halfSize.y));
        float di = sdRoundBox(p - s.center, s.halfSize, r, s.cornerExponent);
        d = lgSmin(d, di, u.mergeRadius);
    }
    return d;
}

// every shape's tint weighted by how close the pixel is to it, so tints blend across a neck
static float4 sceneTint(float2 p, constant LGUniforms &u, constant LGShape *shapes) {
    int n = int(u.shapeCount);
    float3 rgb = float3(0.0);
    float strength = 0.0;
    float weights = 0.0;
    for (int i = 0; i < n; ++i) {
        LGShape s = shapes[i];
        float r = min(s.cornerRadius, min(s.halfSize.x, s.halfSize.y));
        float di = sdRoundBox(p - s.center, s.halfSize, r, s.cornerExponent);
        float w = exp(-max(di, 0.0) / (3.0 * u.scale));
        rgb += s.tint.rgb * s.tint.a * w;
        strength += s.tint.a * w;
        weights += w;
    }
    return float4(rgb / max(strength, 1.0e-5), strength / max(weights, 1.0e-5));
}

// MARK: - Glass

fragment float4 lg_glass(VOut in [[stage_in]],
                         constant LGUniforms &u [[buffer(0)]],
                         constant LGShape *shapes [[buffer(1)]],
                         texture2d<float> sharpTex [[texture(0)]],
                         texture2d<float> blurTex  [[texture(1)]]) {
    float2 p = in.uv * u.viewSize;              // px, origin top-left
    float  d = sceneSDF(p, u, shapes);

    // 1px analytic antialiasing straight off the SDF. No layer mask needed.
    float alpha = clamp(0.5 - d, 0.0, 1.0);
    if (alpha <= 0.001) return float4(0.0);

    const float3 LUMA = float3(0.2126, 0.7152, 0.0722);
    float2 originUV = u.backdropOrigin * u.backdropInvSize;
    float2 uvScale  = u.backdropInvSize / u.scale;          // px -> normalized
    float2 baseUV   = originUV + p * uvScale;

    // one grey for every shape, with a hairline edge so it still reads
    if (u.solid > 0.0) {
        float3 plate = float3(u.solid);
        float4 tintSolid = sceneTint(p, u, shapes);
        plate = mix(plate, tintSolid.rgb, tintSolid.a);
        float edge = 1.0 - clamp(-d / max(u.scale, 1.0), 0.0, 1.0);
        plate = mix(plate, float3(1.0 - u.solid), 0.16 * edge);
        return float4(plate * alpha, alpha);
    }

    // Outward-pointing 2D gradient of the field.
    // central differences = 4 extra SDF evals/px. Fine for UI-sized
    // elements; go analytic if you ever put glass over the whole screen.
    const float e = 1.0;
    float2 g = float2(sceneSDF(p + float2(e, 0.0), u, shapes) - sceneSDF(p - float2(e, 0.0), u, shapes),
                      sceneSDF(p + float2(0.0, e), u, shapes) - sceneSDF(p - float2(0.0, e), u, shapes));
    g = normalize(g + float2(1.0e-6, 0.0));

    // --- Bevel height profile -------------------------------------------
    // x: 0 at the outer edge, 1 at full bevel depth.
    // Apple's preferred profile is the convex squircle h = (1 - (1-x)^4)^(1/4)
    // (softer shoulder than a sphere, holds up on stretched rectangles).
    float bevel = max(u.lightDirBevel.w, 0.5);
    float x  = clamp(-d / bevel, 0.0, 1.0);
    float uu = 1.0 - x;
    float u4 = uu * uu * uu * uu;
    float h  = pow(max(1.0 - u4, 1.0e-4), 0.25);
    float dhdx = min((uu * uu * uu) / (h * h * h), 40.0);   // -> inf at the rim, clamped

    // --- Refraction (Snell, air -> glass) --------------------------------
    float  slope = dhdx * u.thickness / bevel;
    float3 N = normalize(float3(g * slope, 1.0));
    float3 R = refract(float3(0.0, 0.0, -1.0), N, 1.0 / max(u.ior, 1.0001));
    float2 disp = (R.xy / max(-R.z, 1.0e-3)) * u.thickness;
    disp = clamp(disp, -u.thickness * 6.0, u.thickness * 6.0);

    // --- Backdrop sampling ------------------------------------------------
    float edgeW = 1.0 - x;                                   // aberration lives on the rim
    float ca    = u.chroma * edgeW;
    float3 sharp;
    sharp.r = sharpTex.sample(lgSampler, baseUV + disp * (1.0 + ca) * uvScale).r;
    sharp.g = sharpTex.sample(lgSampler, baseUV + disp                * uvScale).g;
    sharp.b = sharpTex.sample(lgSampler, baseUV + disp * (1.0 - ca) * uvScale).b;

    float3 blurC = blurTex.sample(lgSampler, baseUV + disp * 0.35 * uvScale,
                                  level(u.blurLOD)).rgb;

    // Rim reads the lens, the core reads the frost.
    float3 col = mix(sharp, blurC, u.frost * smoothstep(0.0, 1.0, x));

    // --- Material ---------------------------------------------------------
    col = mix(float3(dot(col, LUMA)), col, u.saturation);

    // Adaptive veil: glass goes light over bright content and dark over dark
    // content, which is what keeps a label on top legible either way. Read off
    // a coarser mip so it tracks the neighborhood, not one pixel.
    float3 ambient = blurTex.sample(lgSampler, baseUV, level(u.blurLOD + 3.0)).rgb;
    float bgL      = dot(ambient, LUMA);
    float lightness = smoothstep(0.28, 0.78, bgL);
    float veilA     = mix(u.darkVeil, u.lightVeil, lightness) * u.adaptivity;
    col = mix(col, float3(lightness), veilA);
    float4 tint = sceneTint(p, u, shapes);
    col = mix(col, tint.rgb, tint.a);

    // --- Light ------------------------------------------------------------
    // The highlight is a thin arc hugging the edge, not a soft blob over the
    // whole bevel: dot(N,H) alone stays high across the shoulder, so it gets
    // windowed radially. dot(N,H) still decides *which side* lights up.
    float rimBand = exp(-pow((x - 0.16) / 0.19, 2.0));

    float3 V = float3(0.0, 0.0, 1.0);
    float3 L = normalize(u.lightDirBevel.xyz);
    float3 H = normalize(L + V);
    float spec = pow(max(dot(N, H), 0.0), u.shininess) * rimBand;

    // Second lobe on the opposite rim, light that made it through the glass.
    float3 L2 = normalize(float3(-L.x, -L.y, L.z));
    float3 H2 = normalize(L2 + V);
    float spec2 = pow(max(dot(N, H2), 0.0), u.shininess) * rimBand * 0.5;

    float fres = pow(1.0 - clamp(N.z, 0.0, 1.0), 6.0);
    float light = ((spec + spec2) * u.specular + fres * u.fresnel) * (1.0 - 0.35 * lightness);

    // Contact darkening on the rim facing away from the light.
    float shade = clamp(-dot(g, L.xy), 0.0, 1.0) * edgeW * u.innerShadow;

    // light as white, shade as black, one premultiplied layer
    if (u.overlay > 0.5) {
        float lit = saturate(light);
        float cover = lit + saturate(shade) * (1.0 - lit);
        return float4(float3(lit) * alpha, cover * alpha);
    }

    col += light;
    col *= (1.0 - shade);

    return float4(saturate(col) * alpha, alpha);   // premultiplied
}
