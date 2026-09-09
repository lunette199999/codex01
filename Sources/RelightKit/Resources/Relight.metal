//  Relight.metal
//  2.5D portrait relighting.
//
//  Port of `shade()` in tools/relight_reference.py. That file is the canonical
//  definition of the model; if the two ever disagree, the Python one is right.
//  Parameter names are kept identical across both so they can be diffed by eye.
//
//  Each layer is drawn as its own quad, back to front, with its own parallax
//  offset. That is what separates this from a single-plane warp: the layers
//  slide against each other, so hair occludes and reveals the face instead of
//  the whole portrait shearing as one sheet.

#include <metal_stdlib>
using namespace metal;

struct RelightUniforms {
    float4 keyDir;        // xyz = direction toward light, w = intensity
    float4 keyColor;      // rgb = colour,                 w = wrap
    float4 fillDir;       // xyz,                          w = intensity
    float4 fillColor;     // rgb,                          w = wrap
    float4 rimDir;        // xyz,                          w = intensity
    float4 rimColor;      // rgb,                          w = power
    float4 ambientColor;  // rgb,                          w = intensity
    float4 sssColor;      // rgb,                          w = intensity
    float4 params;        // x = sssPower, y = specIntensity, z = specGloss, w = exposure
    float4 layer;         // x = layerParallax, y = parallaxScale, z = coverageSlot, w = opacity
    float4 parallax;      // xy = parallax input in NDC, zw unused
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// --- colour ---------------------------------------------------------------
// Shade in linear, present in sRGB. Compositing lit colour in gamma space is
// the usual reason hand-rolled relighting goes chalky through the midtones.

inline float3 srgbToLinear(float3 c) {
    return select(c / 12.92f, pow((c + 0.055f) / 1.055f, 2.4f), c > 0.04045f);
}

inline float3 linearToSrgb(float3 c) {
    c = max(c, 0.0f);
    return select(c * 12.92f, 1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c > 0.0031308f);
}

// --- lighting -------------------------------------------------------------

// Lambert with the terminator pushed around the form. Keeps the peak at 1.0
// while lifting the shadow edge, so falloff across a cheek runs long and soft
// instead of stopping dead at 90 degrees. Set wrap to 0 for plain Lambert.
inline float wrapDiffuse(float ndl, float w) {
    return saturate((ndl + w) / (1.0f + w));
}

float3 shadeRelight(float3 albedo, float3 N, float ao, constant RelightUniforms &u) {
    const float3 V = float3(0.0f, 0.0f, 1.0f);   // orthographic viewer

    const float3 keyDir  = normalize(u.keyDir.xyz);
    const float3 fillDir = normalize(u.fillDir.xyz);
    const float3 rimDir  = normalize(u.rimDir.xyz);

    const float nDotKey  = dot(N, keyDir);
    const float nDotFill = dot(N, fillDir);
    const float nDotRim  = dot(N, rimDir);
    const float nDotView = dot(N, V);

    const float diffuseKey  = wrapDiffuse(nDotKey,  u.keyColor.w)  * u.keyDir.w;
    const float diffuseFill = wrapDiffuse(nDotFill, u.fillColor.w) * u.fillDir.w;

    // Cheap single-scatter stand-in: warmth blooming in the terminator band
    // only, gated by the key term so a fully unlit side does not fluoresce.
    // Real subsurface is a diffusion profile; at portrait scale this reads
    // close enough for three instructions.
    const float scatter = pow(saturate(1.0f - abs(nDotKey)), u.params.x)
                        * saturate(diffuseKey) * u.sssColor.w;

    const float3 H = normalize(keyDir + V);
    const float specular = pow(saturate(dot(N, H)), u.params.z)
                         * u.params.y
                         * step(0.0f, nDotKey);   // never float spec over shadow

    const float fresnel = pow(saturate(1.0f - nDotView), u.rimColor.w);
    const float rim = fresnel * saturate(nDotRim) * u.rimDir.w;

    const float3 ambient = u.ambientColor.rgb * u.ambientColor.w * ao;

    float3 lit = albedo * (ambient
                           + u.keyColor.rgb * diffuseKey
                           + u.fillColor.rgb * diffuseFill * ao);
    lit += albedo * u.sssColor.rgb * scatter;
    lit += u.keyColor.rgb * specular;
    lit += u.rimColor.rgb * rim;

    return lit * u.params.w;
}

// --- stages ---------------------------------------------------------------

vertex VertexOut relightVertex(uint vid [[vertex_id]],
                               constant RelightUniforms &u [[buffer(0)]]) {
    // Unit quad as a triangle strip.
    const float2 corners[4] = {
        float2(-1.0f, -1.0f), float2(1.0f, -1.0f),
        float2(-1.0f,  1.0f), float2(1.0f,  1.0f)
    };

    const float2 p = corners[vid];

    // Offsetting the quad rather than the UVs means the layer's content travels
    // with it, so nothing slides out from under its own sampling window.
    const float2 offset = u.parallax.xy * u.layer.x * u.layer.y;

    VertexOut out;
    out.position = float4(p + offset, 0.0f, 1.0f);
    out.uv = float2((p.x + 1.0f) * 0.5f, 1.0f - (p.y + 1.0f) * 0.5f);
    return out;
}

fragment float4 relightFragment(VertexOut in [[stage_in]],
                                constant RelightUniforms &u [[buffer(0)]],
                                texture2d<float> albedoTex   [[texture(0)]],
                                texture2d<float> normalTex   [[texture(1)]],
                                texture2d<float> aoTex       [[texture(2)]],
                                texture2d<float> coverageTex [[texture(3)]],
                                sampler samp [[sampler(0)]]) {

    const float4 albedoSample = albedoTex.sample(samp, in.uv);
    const float4 cov4 = coverageTex.sample(samp, in.uv);

    // One coverage channel per layer, packed by tools/portrait_maps.py in the
    // order reported as `coverageChannels` in the .maps.json sidecar.
    const int slot = int(u.layer.z);
    float coverage = (slot == 0) ? cov4.r
                   : (slot == 1) ? cov4.g
                   : (slot == 2) ? cov4.b
                                 : cov4.a;

    coverage *= albedoSample.a * u.layer.w;
    if (coverage <= 0.001f) {
        discard_fragment();
    }

    const float3 albedo = srgbToLinear(albedoSample.rgb);
    const float3 N = normalize(normalTex.sample(samp, in.uv).xyz * 2.0f - 1.0f);
    const float ao = aoTex.sample(samp, in.uv).r;

    const float3 lit = linearToSrgb(shadeRelight(albedo, N, ao, u));

    return float4(lit * coverage, coverage);   // premultiplied
}
